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
| **Deploy drift** | `services/drift/` container | That the box's checkout matches the repo — right branch, nothing uncommitted, nothing unpushed | Pushes up/down **with the reason** to a Kuma Push monitor |
| **AutoKuma** | `services/autokuma/` | Nothing — it *declares* the monitor set, reconciling Kuma against `.toml` files in this repo | n/a |

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

**This step stays manual on purpose.** AutoKuma can define notifications, but
its own docs mark that support **experimental and subject to change** — and
this is the one piece of config whose silent breakage means every other alert
goes nowhere. Monitors are declarative; the channel that carries them is worth
clicking once and testing.

### 2 & 3. The monitors — declared in this repo, not clicked

**These are config-as-code.** [services/autokuma/monitors/](../services/autokuma/monitors/)
holds the monitor set as `.toml` files; the `autokuma` service reconciles Kuma
against them. You do not create these by hand, and you do not re-create them
after a rebuild — AutoKuma puts them back.

| Monitor | Type | Target |
| ------- | ---- | ------ |
| Pocket ID | HTTP | `http://pocket-id:1411` |
| Vaultwarden | HTTP | `http://vaultwarden:80/alive` |
| Ente (museum API) | HTTP | `http://ente-museum:8080/ping` |
| Ente (web) | HTTP | `http://ente-web:3000` |
| Jellyfin | HTTP | `http://jellyfin:8096/health` |
| Open WebUI | HTTP | `http://open-webui:8080` |
| Edge (public TLS) | HTTP | `https://id.${BASE_DOMAIN}` — the only one exercising DNS → eero → OPNsense → Caddy → TLS, so also the noisiest |
| Nightly backup | Push | dead-man's-switch |
| SMART (apps VM) | Push | dead-man's-switch |
| SMART (Proxmox host) | Push | dead-man's-switch |
| Deploy drift (apps VM) | Push | dead-man's-switch |

To change the monitor set, edit a file and redeploy. To add one, drop in a new
`.toml`. **Keep filenames stable** — the filename is AutoKuma's ID for the
monitor, so renaming a file orphans the old monitor and creates a new one.

#### The push tokens are pinned, which removes the copy-paste step

Push monitors normally mean: create the monitor in the UI, copy the token Kuma
generated, paste it into a config file. AutoKuma can **pin** the token instead,
so `setup.sh` generates it first and wires both ends — the monitor definition
*and* `HEALTHCHECK_URL` in [services/backup/.env](../services/backup/.env.example)
and [services/smart/.env](../services/smart/.env.example). Nothing to copy.

Two things to know:

- The token format is enforced: **exactly 32 characters, letters and digits**.
  A malformed one is not a loud failure — AutoKuma skips the monitor and logs a
  `WARN` each sync cycle, so it just never appears. If a push monitor is
  missing, read `docker logs autokuma` before anything else.
- Tokens are **secrets**. Anyone holding one can post a fake "all is well"
  heartbeat and keep a monitor green while the real job fails. That's why the
  push definitions are `.toml.template` files rendered on the box, and why
  nothing rendered is ever committed.
- `setup.sh` fills `HEALTHCHECK_URL` only when it is **blank**. If you've
  pointed one at healthchecks.io or elsewhere deliberately, it says so and
  leaves it alone rather than overwriting your choice.

#### ⚠️ AutoKuma's `/data` volume is load-bearing

AutoKuma remembers which Kuma monitor belongs to which definition in
`/data/autokuma.db`, and **the image declares no volume of its own**. Without
the persistent mount in
[its compose file](../services/autokuma/docker-compose.yml), every `compose up`
that recreates the container forgets those mappings and creates a **second copy
of every monitor**. Measured: the count went 3 → 5 on one recreation, then held
at 5 across two more once `/data` persisted. Duplicates don't self-heal —
AutoKuma only manages what it remembers — so orphans must be deleted by hand.

### Deploy drift — the monitor that watches the deploy itself

Every other monitor here asks "is the service up?". This one asks a different
question: **is the box running what the repo says it is?**

The deploy model ([DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md)) is one-way —
changes flow repo → box via `git pull`, and the box is a pull-only target.
Nothing enforced that. On **2026-08-28** the box was found sitting on a feature
branch carrying three commits that existed on no other machine: the only copy of
that day's storage-incident writeup lived on the disk the incident was about. A
routine `git pull` reported success and fetched nothing, because the branch had
no upstream.

That is the shape of the failure worth naming. `DEPLOY_ARCHITECTURE.md` already
specs a deploy primitive for **merged-but-not-deployed**. This is the mirror
image — **deployed-but-not-merged** — and until now only one direction was
instrumented.

The check runs daily at 06:10 and reports drift when any of these hold:

| Finding | Why it matters |
| ------- | -------------- |
| Not on the expected branch | The 2026-08-28 case. A `git pull` here is a silent no-op. |
| Uncommitted changes to tracked files | Someone edited the box directly; the change exists nowhere else. |
| Commits not pushed | **The dangerous one.** Work that exists only on this disk. |
| Behind `origin/main` | Merged but not deployed — the other direction. |

Untracked files are deliberately **not** flagged: the box legitimately carries
gitignored per-service `.env` files, and alerting on those daily is how a
monitor gets muted and stops being a monitor.

It is **read-only by construction** — it never fetches, checks out, or pushes.
It reads local git state and asks origin a single `git ls-remote` question
(anonymous, the repo is public), and the repo is mounted `:ro`. A monitor that
can mutate the deploy tree is a worse problem than the drift it watches.

The rule this encodes isn't "never commit on the box" — during a live incident
the box is often the only place the diagnosis can happen. It's **"if you commit
on the box, push before you close the session."**

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
