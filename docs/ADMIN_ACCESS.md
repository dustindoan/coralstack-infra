# Admin access

How privileged UIs are reached, and the rules new services must follow.

The repo has two classes of UI:

- **Data plane** — member-facing. Members log into Jellyfin, Vaultwarden, Ente. These
  go through Caddy + Pocket ID and are public.
- **Admin plane** — operator-facing. The hypervisor, the firewall, the library
  manager for TubeArchivist, the MinIO console, etc. These must never be reachable
  from the public internet.

The cost of getting these mixed up is asymmetric: misclassifying a member service as
admin-only is mild friction; misclassifying an admin UI as member-facing is a breach.
Default to admin-plane treatment when in doubt.

## Taxonomy

Three categories of admin UI, with different ownership:

| Category | Examples | Repo controls bind address? |
| -------- | -------- | --------------------------- |
| **Hardware / hypervisor** | Proxmox (`:8006`), OPNsense web UI, IPMI/BMC | No — host admin handles |
| **Service-admin-only** | TubeArchivist, MinIO console, future Grafana/Loki, future Letta UI | Yes — see [the rule](#the-rule) |
| **Privileged routes on public services** | Vaultwarden `/admin`, Jellyfin dashboard, Pocket ID admin tab | Already public, each service's auth is the gate |

The third category is handled by per-service auth — don't change anything there. The
rest of this doc is about categories 1 and 2.

## The rule

> Any service whose **entire web UI is admin-only** MUST bind to the host's loopback
> interface in its compose file, unless explicitly justified in a code comment.

Concretely, in a `services/<name>/docker-compose.yml`:

```yaml
ports:
  - "127.0.0.1:8000:8000"   # admin-plane — reach via ssh -L (see docs/ADMIN_ACCESS.md)
```

Not:

```yaml
ports:
  - "8000:8000"             # binds 0.0.0.0 — exposes on LAN
```

And no Caddy entry. If the UI doesn't go through Caddy, it doesn't get a public
hostname, doesn't get a Let's Encrypt cert, doesn't show up in any DNS record.

For services that **don't** publish any port (only reach other containers via the
`coralstack` network) the rule is moot — those are already inaccessible from the
host, never mind the public internet. The MinIO console at `ente-minio:3201` is in
this shape today.

## Reach mechanisms (current — Phase 1)

### A. SSH local-forward (default for off-network admin)

You're at home: open the URL on your laptop's browser, which is on the same LAN as
the NUC — works directly only if the service binds to the NUC's LAN IP. With the
loopback-only rule above, you need to tunnel.

```bash
# Example: TubeArchivist
ssh -L 8000:localhost:8000 nuc
# Then http://localhost:8000 on your laptop
```

Multiple services at once:

```bash
ssh -L 8000:localhost:8000 -L 8006:localhost:8006 nuc
```

This works from anywhere SSH works — same network, coffee shop, vacation — provided
your SSH key is on the NUC.

### B. LAN-direct (for hardware UIs you can't bind to loopback)

Proxmox and OPNsense bind to their VM's NIC, not to loopback on the host. From a
device on the LAN (or on the OPT1 admin VLAN for OPNsense), you reach them directly
by IP:

- Proxmox: `https://<nuc-lan-ip>:8006`
- OPNsense: `https://10.0.0.1` (LAN side) or `https://10.0.1.1` (OPT1)

Off-network access requires either SSH-tunneling through the NUC (if it can reach
those IPs, which it can) or a VPN — see [Phase 1.5](#phase-15--headscale).

## Reach mechanisms (Phase 1.5+ — see [HEADSCALE.md](HEADSCALE.md))

Once Headscale is deployed:

- All admin devices (laptop, phone, NUC, Mac mini) join the tailnet
- Admin UIs become reachable via MagicDNS (e.g., `tube.nuc`, `proxmox.nuc`)
  from any tailnet member, no per-service tunneling
- SSH tunneling stays as a fallback when Headscale itself is the thing you're
  debugging

The loopback-bind rule still applies. Tailnet reachability comes from binding
to the `tailscale0` interface in addition to loopback, not from removing the
loopback constraint.

## Reach mechanisms (Phase 2+) — shared admin

When a second admin joins, you may want some admin UIs reachable to them without
issuing tailnet credentials. That's the case for **Caddy `forward_auth` →
Pocket ID** in front of select admin UIs, scoped to an `admins` group.

This is *only* for admin UIs that are tolerable to expose with strong auth in
front. Hardware UIs (Proxmox, OPNsense) stay tailnet-only — they're too
privileged to ever expose, even with SSO.

Not yet implemented; design lives in this section so future-you knows where it'll
land.

### Uptime Kuma: no native SSO is coming — don't wait for it

Checked 2026-08-25. Kuma has **no login SSO in any release**, 2.4.0 included.
Two OIDC pull requests ([#6161](https://github.com/louislam/uptime-kuma/issues/6161),
[#6232](https://github.com/louislam/uptime-kuma/pull/6232)) were both closed
unmerged in October 2025; the maintainer declined to own a hand-rolled OIDC
implementation ("I will not be able to maintain it in the future") and stated a
preference for migrating auth to **Better Auth**, which would bring OIDC as a
library feature. That migration is the realistic route, not another OIDC PR.

> **Don't be fooled by the Authelia "Uptime Kuma / OpenID Connect" guide.** It
> configures Kuma's *outbound monitor* authentication — OAuth2 **client
> credentials**, so a monitor can probe an OAuth-protected endpoint. Client
> credentials is machine-to-machine and has no user login step, so it cannot be
> login SSO. It's a monitor setting, not an auth setting.

So Kuma belongs with the *arr stack in the "will never self-SSO" bucket, and
`forward_auth` is the only path to putting it behind Pocket ID.

### `forward_auth` on Kuma must be path-scoped, not host-wide

The instinct is to protect `status.<domain>` and be done. **That breaks things,
some of them silently.** Three paths on that vhost must stay unauthenticated:

| Path | Why it must stay open |
| ---- | --------------------- |
| `/status/*` | The public status page — the entire point of the vhost, and the mitigation members rely on when a cached PWA failure state lies to them |
| `/api/push/*` | The push endpoints the nightly backup and **both** SMART checks post their heartbeats to (see [MONITORING.md](MONITORING.md)) |
| Status-page static assets | The public page won't render without them |

Both failure directions are bad, and they're asymmetric:

- **Too broad** — the dead-man's-switches start returning 401. The heartbeats
  stop arriving, Kuma reports the monitors as down, and the alerts you get are
  about the alerting rather than about the stack. Worse, it looks exactly like
  a real backup failure, so it burns trust in the signal.
- **Too narrow** — the admin UI stays exposed, which is
  [SEC-2](SECURITY_PASS.md#sec-2-medium--unclaimed-first-run-setup-wizard-on-a-public-vhost)
  all over again.

Whoever implements layer 3 should test the push endpoints **first** — before
trusting a single alert from them afterward.

## Registry of admin UIs

This is the authoritative list. Keep in sync with reality.

> ⚠️ The **Phase 1.5 column is aspirational**, and more so than it looks.
> MagicDNS names *hosts*, not services — so Headscale alone gives you
> `coralstack-apps:<port>`, not `home.nuc`. Per-service names need
> `dns.extra_records` plus a Caddy listener on `tailscale0`, and the `.nuc`
> suffix would additionally need an internal CA. See
> [HEADSCALE.md](HEADSCALE.md#magicdns-names-hosts-not-services--the-registry-oversells-this).

| UI | Port | Bind | How to reach (Phase 1) | Phase 1.5 (Headscale) |
| -- | ---- | ---- | ---------------------- | --------------------- |
| Proxmox | 8006 | hypervisor NIC | `https://<nuc-lan-ip>:8006` from LAN | `https://proxmox.nuc` |
| OPNsense | 443 | LAN + OPT1 NICs | `https://10.0.0.1` from LAN | `https://opnsense.fw` |
| TubeArchivist | 8000 | 127.0.0.1 | `ssh -L 8000:localhost:8000 nuc` | `https://tube.nuc` |
| Dispatcharr | 9191 | 127.0.0.1 (port published by `dispatcharr-vpn` Gluetun sidecar) | `ssh -L 9191:localhost:9191 coralstack-apps` | `https://tv.nuc` |
| Sonarr | 8989 | 127.0.0.1 (port published by `arr-vpn` Gluetun sidecar) | `ssh -L 8989:localhost:8989 coralstack-apps` | `https://sonarr.nuc` |
| Radarr | 7878 | 127.0.0.1 (port published by `arr-vpn` Gluetun sidecar) | `ssh -L 7878:localhost:7878 coralstack-apps` | `https://radarr.nuc` |
| Prowlarr | 9696 | 127.0.0.1 (port published by `arr-vpn` Gluetun sidecar) | `ssh -L 9696:localhost:9696 coralstack-apps` | `https://prowlarr.nuc` |
| qBittorrent | 8090 | 127.0.0.1 (port published by `arr-vpn` Gluetun sidecar) | `ssh -L 8090:localhost:8090 coralstack-apps` | `https://qbit.nuc` |
| Portainer | 9443 | 127.0.0.1 | `ssh -L 9443:localhost:9443 coralstack-apps` → `https://localhost:9443` (self-signed cert warning expected) — **holds docker.sock = root-equivalent on the host**; strictest gate | `https://portainer.nuc` |
| Homepage (admin front door) | 3000 | 127.0.0.1 | `ssh -L 3000:localhost:3000 coralstack-apps` — config-as-code in [services/homepage/config](../services/homepage/config); no auth of its own (SSH possession is the credential) | `https://home.nuc` |
| CoralStack admin panel | 9090 | 127.0.0.1 | `ssh -L 9090:localhost:9090 coralstack-apps` — **no login of its own**: SSH possession is the credential (loopback rule); cross-site POSTs rejected, actions confirm-gated. See [services/admin-panel](../services/admin-panel/docker-compose.yml), [ENTE_STORAGE.md](ENTE_STORAGE.md) | `https://admin.nuc` |
| MinIO console (Ente) | 3201 | container network only | `docker compose exec` or `ssh -L 3201:ente-minio:3201 nuc` | (no change — internal only) |

Future entries will appear here when added. If you're adding a service and aren't
sure whether it belongs here or in the public-facing column: ask "would I let a
co-op member click around in this UI?" If no, it goes here.

## Secret tiers

Related but orthogonal — secrets used to *log into* the admin plane are tiered.
From [memory: secret tiering](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_secret_tiering.md):

- **Tier 1** — break-glass: vault master passphrase, infra root credentials,
  Cloudflare API token, Proxmox root. **On paper, in a safe.** Never in
  Vaultwarden (chicken-and-egg if vault is the thing being recovered).
- **Tier 2** — operational: per-service admin passwords (TubeArchivist admin,
  MinIO root, Vaultwarden `/admin` token, Jellyfin admin password). In
  Vaultwarden under the `admin` collection.

The vault master is never reused anywhere else.

## Checklist for new admin-plane services

When adding a service whose web UI is admin-only:

- [ ] Compose file uses `127.0.0.1:PORT:PORT` port mapping (or no published port at all if container-network reachable is enough)
- [ ] **No** Caddy entry, **no** subdomain
- [ ] **No** Caddy network alias added in root `docker-compose.yml`
- [ ] Admin password is Tier 2 — stored in Vaultwarden `admin` collection on first boot
- [ ] Entry added to [the registry above](#registry-of-admin-uis) with reach instructions
- [ ] If `setup.sh` generates a password for it, the password is printed once and the user is reminded to store it in Vaultwarden

## Checklist for new public-plane services

When adding a service that **is** exposed through Caddy on its own subdomain —
the case the admin-plane checklist above doesn't cover, and the one that let
[SEC-2](SECURITY_PASS.md#sec-2-medium--unclaimed-first-run-setup-wizard-on-a-public-vhost)
happen:

- [ ] **Claim the admin account in the same session you deploy it** — or leave it
      loopback-bound until you can. A service with an unclaimed first-run wizard
      is not "authenticated but unconfigured", it is *open to whoever finds it
      first*
- [ ] Admin credential is Tier 2 — into Vaultwarden immediately, not "later"
- [ ] Confirm the service has no "disable authentication" toggle enabled
- [ ] Add a row to the [auth-coverage map](SECURITY_PASS.md#auth-coverage-map-caddy-edge)
      saying how the vhost authenticates
- [ ] Caddy network alias added in root `docker-compose.yml` (see its comment)
- [ ] If anything on the vhost must stay public (status pages, push/webhook
      endpoints), write down which paths — a future `forward_auth` will break
      them otherwise

## Open questions

- **Caddy admin API** (port 2019) — bound to loopback inside Caddy's container by
  default; not currently published to the host. Worth a spot-check next time the
  Caddyfile is touched.
- **Pocket ID admin tab** — same subdomain as member login (`id.<dom>`). Could
  argue this is mixed-plane; Pocket ID handles role separation internally.
  Leaving as-is unless we hit a concrete problem.
