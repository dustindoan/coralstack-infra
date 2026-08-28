# Monitoring & alerting

What is being watched, how a problem reaches a human, and — stated plainly —
what is still not covered.

The guiding distinction: **a dashboard is not an alert.** Uptime Kuma renders a
beautiful green grid that nobody is looking at when a drive starts failing at
3am. Everything below is arranged so that a problem *pushes* to a person.

Related: [HARDWARE_FAILURE.md](HARDWARE_FAILURE.md) (what to do when a finding
lands) · [RECOVERY.md](RECOVERY.md) (power loss) · [BACKUPS.md](BACKUPS.md).

## The pieces

| Piece | Where | Watches | Alerts via |
| ----- | ----- | ------- | ---------- |
| **Uptime Kuma** | apps VM, `status.${BASE_DOMAIN}` | Service reachability; receives push heartbeats | Its own notification channels |
| **Backup dead-man's-switch** | `services/backup/backup.sh` | That the nightly backup actually completed | Pushes to a Kuma **Push** monitor on success; silence = alert |
| **SMART (apps VM)** | `services/smart/` container | The TerraMaster — the disk with the photo blobs | Pushes up/down **with the reason** to a Kuma Push monitor |
| **SMART (Proxmox host)** | `services/smart/host/`, systemd timer | The NUC's M.2 — Proxmox + both VMs' disks | Same, via the public `status.` URL |

Two SMART runners is not redundancy, it's coverage: **the apps VM physically
cannot see the M.2.** From inside the VM that disk is a virtio device with no
SMART data behind it. Neither runner covers the other's disks.

## Setup

Uptime Kuma is already deployed and reachable at `status.${BASE_DOMAIN}`. What
remains is configuration, which lives in Kuma's own SQLite DB — **there is no
config-as-code path for it**. That's the same limitation that got Homarr
removed from the stack (see the dashboard row in [ROADMAP.md](ROADMAP.md)), and
it's why this section is a checklist to work through in the UI rather than a
file to deploy.
That makes this database the **only** source of truth for the config you're
about to build, which is why the nightly backup dumps it through SQLite's online
`.backup` API rather than relying on a raw copy of the data directory.

**This was measured, not assumed.** On a throwaway Kuma 2.4.0 instance with two
monitors configured, copying `kuma.db` on its own — what a plain file-level
backup captures — yielded **zero monitors**. The same copy taken together with
its `-wal` sidecar had both. Kuma runs SQLite in WAL mode, and at that point the
main database was 61 KB against a 1.4 MB write-ahead log: essentially the entire
configuration was living in the file a naive copy leaves behind. Do the setup
once; the `.backup` dump is what stops you doing it twice.

### 1. A notification channel — do this first

Without one, none of the rest alerts anybody.

**Settings → Notifications → Setup Notification.** Pick something that reaches
a phone. Options that need no third-party account: **ntfy** (`ntfy.sh` with a
private random topic, or self-hosted later), or SMTP if you already have a
relay. Then **enable it as the default** so new monitors inherit it, and tick
it on every monitor you create below.

Test it with Kuma's own Test button before trusting it. An untested
notification channel is the same as no notification channel.

### 2. Service monitors

**Add New Monitor → HTTP(s)** for each. Use the internal container address
where one exists — it isolates "the service is down" from "the internet is
down", which are very different 3am problems.

| Name | Type | Target |
| ---- | ---- | ------ |
| Pocket ID | HTTP(s) | `http://pocket-id:1411` |
| Vaultwarden | HTTP(s) | `http://vaultwarden:80/alive` |
| Ente (museum API) | HTTP(s) | `http://ente-museum:8080/ping` |
| Ente (web) | HTTP(s) | `http://ente-web:3000` |
| Jellyfin | HTTP(s) | `http://jellyfin:8096/health` |
| Open WebUI | HTTP(s) | `http://open-webui:8080` |
| Caddy / public edge | HTTP(s) | `https://id.${BASE_DOMAIN}` |

The last one is deliberately the *public* URL: it's the only monitor that
exercises the whole chain (DNS → eero forward → OPNsense NAT → Caddy → TLS).
Expect it to be the noisy one, because it fails for reasons outside the box.

> Pocket ID and Ente-web answer on `/` with a redirect or a 200 — set the
> accepted status codes to `200-399` rather than fighting it.

### 3. Push monitors (the dead-man's-switches)

These are the important ones. A push monitor alerts on **silence**, which is
the failure mode that HTTP checks structurally cannot catch: the nightly backup
silently not running looks exactly like a healthy system.

**Add New Monitor → Monitor Type: Push** for each, then paste the generated
Push URL into the matching config file on the box.

| Name | Heartbeat interval | Paste the URL into | Why that interval |
| ---- | ------------------ | ------------------ | ----------------- |
| Nightly backup | `172800` (2 days) | `services/backup/.env` → `HEALTHCHECK_URL` | Backup runs 03:15 daily; two days tolerates one skipped run without crying wolf |
| SMART (apps VM) | `172800` (2 days) | `services/smart/.env` → `HEALTHCHECK_URL` | Check runs 06:20 daily |
| SMART (Proxmox host) | `172800` (2 days) | `/etc/coralstack/smart.env` → `HEALTHCHECK_URL` | Check runs 06:50 daily |

The container-side URLs can use the internal name
(`http://uptime-kuma:3001/api/push/<token>`). **The Proxmox host cannot** — it
isn't on the coralstack docker network — so it must use
`https://status.${BASE_DOMAIN}/api/push/<token>`, which hairpins back through
eero.

Then restart the affected services so they pick up the new value:

```bash
docker compose up -d backup smart
```

The SMART checks don't only heartbeat — they push `status=down` **with the
finding text** the moment a drive reports a problem, so you get "8 pending
sectors on /dev/sdb" rather than a bare "monitor is down". Both mechanisms are
live at once: a finding alerts immediately, and a runner that dies entirely
alerts when its heartbeat lapses.

### 4. An external check — the one that catches a dead box

Everything above runs **on the machine it is monitoring**. If the NUC dies,
Kuma dies with it and nothing alerts. This step is the only one that survives
that, and it takes about five minutes.

Pick one:

**Option A — a free hosted monitor (simplest).** Create an account on
UptimeRobot, Better Stack, or healthchecks.io and point a check at
`https://status.${BASE_DOMAIN}` every 5 minutes, with alerts to the same phone
as everything else. Privacy cost is essentially nil: the status page is already
public by design, so the provider learns nothing that isn't.

**Option B — a cron on a machine somewhere else.** Any always-on box outside
this house — a friend's server, a cheap VPS, a future co-op member's node:

```bash
*/5 * * * * curl -fsS -m 15 https://status.<BASE_DOMAIN> >/dev/null || \
  curl -fsS -d "coralstack unreachable from $(hostname)" ntfy.sh/<your-private-topic>
```

> **The Mac mini does not count.** It's a separate box, so it survives the NUC
> dying — but its internet path is OPNsense, which runs *on* the NUC. When the
> NUC goes, the Mac mini can still see that the stack is down and has no way to
> tell you. Same failure domain for alerting purposes, despite being separate
> hardware.

Whichever you pick, **test it by actually stopping Caddy** (`docker compose
stop caddy`) and confirming the alert arrives before you start it again. An
external check you've never seen fire is a guess.

### 5. The public status page

Already live at `status.${BASE_DOMAIN}`. Keep the *member-facing* services on
it (Jellyfin, Ente, Vaultwarden, Pocket ID) and keep the SMART and backup
monitors **off** it — members don't need drive telemetry, and it's operational
detail about the host's internals.

This page exists mainly to defuse the PWA failure-state trap: Jellyfin and Ente
service workers cache failure responses and keep showing a stale error after
recovery, so a member needs somewhere independent to see "it's actually back —
restart your browser." That's the line
[MEMBER_ONBOARDING.md](MEMBER_ONBOARDING.md) points them at.

## What is still not covered

Stated explicitly, because a monitoring doc that only lists wins is how you end
up believing you have coverage you don't.

- **Kuma cannot alert you that Kuma is down** — until you do step 4 above.
  It runs on the apps VM, on the NUC; if the NUC dies, the monitoring dies with
  it and you find out from a family member, not a notification. Everything else
  in this document assumes the box is alive enough to tell you something is
  wrong. **Until step 4 is set up and tested, that assumption is the weakest
  link in the whole alerting story.**
- **No filesystem-level corruption detection.** SMART tells you the *drive* is
  unhealthy. It says nothing about silent bit-rot in a file, which is what
  checksumming filesystems (ZFS/btrfs) exist for and ext4 does not do. The
  partial mitigation is restic: `restic check --read-data-subset` verifies
  backed-up data end-to-end (see [BACKUPS.md](BACKUPS.md)).
- **No capacity alerting.** A disk filling up takes services down just as
  effectively as a disk dying, and nothing currently watches free space. Kuma
  can't do it natively; it needs a small push script (the same pattern as
  `smart-check.sh`) or a real metrics stack.
- **No metrics/history.** Everything here is binary up/down at a point in time.
  "Is this drive's temperature trending up over six months?" is unanswerable —
  that's the deferred Grafana/Loki item in [ROADMAP.md](ROADMAP.md). The weekly
  `--full` SMART dump in the container logs is the poor-man's substitute.
- **Nothing watches OPNsense or Proxmox themselves** beyond the host SMART
  timer — no CPU, memory, thermal, or fan monitoring on any box.
