# Roadmap

What's planned, what's in flight, and what's deferred — for the **coralstack-infra**
repo specifically. The member-side migration tooling lives in the
[puddle + duckling projects](#related-projects).

This doc is an **index**, not a substance doc. Each work item links to a spec, runbook,
or open question. If a row says "TBD" in the doc column, the thinking exists (often in
session memory) but hasn't been written down yet — capture it before you build it.

> **"design note"** anywhere in these docs means the maintainer's working notes on a
> decision. They are deliberately **not in this repo** — they're session memory, not
> published artefacts — so they are referred to by name rather than linked. Where a row
> below says *promote*, the intent is to turn one into a real doc in `docs/`; until then,
> treat the note as context that exists but that a reader of this repo can't open.

## Phase framing

Phases describe the **deployment shape**, not a calendar. We move to the next phase
when friction in the current one demands it — not on a schedule.

| Phase | Shape | Trigger to advance |
| ----- | ----- | ------------------ |
| **1** | Single NUC, single co-op (Campbell River), one admin | Service set is stable; trial validates the model |
| **1.5** | Same hardware, but admin/ops maturity work | SSH-tunnel toll annoys you, or backups become non-negotiable |
| **2** | Multi-household on the same host; possibly a second admin | A second household commits to joining |
| **3** | Multi-host or productized for re-deploy by other co-ops | Demand from a second co-op, or hardware product opportunity |

Phase 1 trial state is **expendable** — see
the trial-state-expendable design note.
Don't over-engineer migration paths within Phase 1.

---

## Phase 1 — Trial (current)

Single NUC, Campbell River, one admin. Get the service set stable and the household
onto self-hosted infrastructure for real daily use.

**Pre-public-launch punch list:** [docs/LAUNCH_BLOCKERS.md](LAUNCH_BLOCKERS.md) — the
short-term tactical doc of what's between us and a public coralstack.org. References
back into this roadmap and into memory for items that don't yet have docs.

### Service stack
| Item | Status | Doc |
| ---- | ------ | --- |
| Pocket ID (OIDC) | ✅ deployed | [ONBOARDING.md](ONBOARDING.md) |
| Vaultwarden | ✅ deployed (SSO via Timshel fork) | [ONBOARDING.md](ONBOARDING.md) |
| Ente Photos | ✅ deployed | [ONBOARDING.md](ONBOARDING.md) |
| Jellyfin | ✅ deployed | [ONBOARDING.md](ONBOARDING.md) |
| Dispatcharr (IPTV → Jellyfin Live TV) | ✅ deployed (admin-plane) | [services/dispatcharr](../services/dispatcharr/docker-compose.yml), [ADMIN_ACCESS.md](ADMIN_ACCESS.md) |
| Open WebUI | ✅ deployed (Ollama on Mac mini) | [PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) Phase 4c |
| Uptime Kuma (monitoring + public `status.` page) | 🚧 in repo, deploy pending | [services/uptime-kuma](../services/uptime-kuma/docker-compose.yml) — independent status page mitigates the PWA failure-state trap; hosts the backup dead-man's-switch |
| *arr stack (Sonarr/Radarr/Prowlarr/qBittorrent) | ✅ deployed (admin-plane, shared `arr-vpn` Gluetun netns) | [services/arr](../services/arr/docker-compose.yml) — single `${STORAGE_PATH}/media` mount so imports hardlink; indexers are runtime config, not repo state |
| Portainer (Docker management) | ✅ deployed (admin-plane) | [services/portainer](../services/portainer/docker-compose.yml) — holds `docker.sock`, so strictest gate; a window + break-glass lever, not the source of truth |
| YouTube archiving (TubeArchivist vs Pinchflat) | 💭 undecided | Neither deployed. Pinchflat fits the stack better (one container, writes NFO into a Jellyfin library) but upstream has been dormant since 2025-12; TubeArchivist is actively maintained but needs Elasticsearch + Redis and wants to be its own frontend |
| Music acquisition pipeline (buy → beets → Jellyfin) | 💭 specced (hand-off) | [MUSIC_ACQUISITION.md](MUSIC_ACQUISITION.md) — ongoing purchase→library workflow (gate #2); existing-library migration is a separate member-side tool, home TBD (was planned for the now-archived coralstack-migrator) |

### Infrastructure
| Item | Status | Doc |
| ---- | ------ | --- |
| Proxmox + OPNsense migration | ✅ runbook complete | [PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) |
| Caddy edge + Cloudflare DNS-01 | ✅ deployed | [QUICKSTART.md](QUICKSTART.md) |
| Mount-points fail closed | ✅ convention | TBD — promote from memory to per-service comments |
| Host OS = Ubuntu Server LTS | ✅ convention | [QUICKSTART.md](QUICKSTART.md) |

### Admin/ops
| Item | Status | Doc |
| ---- | ------ | --- |
| Admin access spec (loopback bind + SSH tunnel) | 🚧 drafting | [ADMIN_ACCESS.md](ADMIN_ACCESS.md) |
| Ente deletion janitor (bounded purge window) | 🚧 in repo, deploy pending | [ENTE_STORAGE.md](ENTE_STORAGE.md) — shrinks Ente's hard-coded 45-day purge queue to N days, post-backup; caps deleted-photo disk churn |
| Admin panel (loopback action panel) | 🚧 in repo, deploy pending | [services/admin-panel](../services/admin-panel/docker-compose.yml) — purge-pending gauge + "expedite Ente deletions" action; seed of the Phase 1.5 admin front door |
| Power-loss recovery | ✅ runbook complete | [RECOVERY.md](RECOVERY.md) |
| Secret tiering (Tier 1 paper / Tier 2 vault) | ✅ convention | [ADMIN_ACCESS.md](ADMIN_ACCESS.md#secret-tiers) |

---

## Phase 1.5 — Friction-driven maturity

Triggered when SSH-tunnel admin gets annoying, or when "Jellyfin lost my watch progress
again" makes backups non-negotiable.

| Item | Status | Doc |
| ---- | ------ | --- |
| Headscale (self-hosted tailnet) | 📋 specced | [HEADSCALE.md](HEADSCALE.md) |
| GPU transcoding (Jellyfin QSV via iGPU passthrough) | ✅ done (2026-06-23) | [GPU_TRANSCODING.md](GPU_TRANSCODING.md) — Iris 650 passed to apps VM 101; Jellyfin has /dev/dri. Remaining: enable QSV in Jellyfin UI |
| Admin front door **layer 1** — Homepage dashboard | ✅ deployed (admin-plane) | [services/homepage](../services/homepage/docker-compose.yml) — config-as-code YAML in the repo. Homarr was tried 2026-08-07 and removed: boards/integrations live only in its SQLite DB with no API to write them, so every install needs manual UI work |
| Admin front door **layer 2** — reachability (Headscale) | 📋 specced, **trigger fired** | [HEADSCALE.md](HEADSCALE.md) — the ssh-tunnel toll is now the top usability complaint (7 forwarded ports to use the dashboard's own links). Next discrete project |
| Admin front door **layer 3** — SSO gate (Caddy forward_auth → Pocket ID) | 📋 deferred, see caveat | [ADMIN_ACCESS.md](ADMIN_ACCESS.md#phase-2) — scoped to the *second admin* case. Two things to know before building: it reverses [the loopback rule](ADMIN_ACCESS.md#the-rule) by exposing admin UIs via Caddy, and on its own it only *adds* a login — collapsing to one login also needs each *arr set to `External` authentication |
| Backup strategy implementation | ✅ deployed + restore-tested (DBs+configs to B2 CA-East); photo upload deferred until migration settles | [BACKUPS.md](BACKUPS.md) — restic+rclone service ([services/backup](../services/backup/)), cloud-agnostic |
| Service update strategy (pin tags → Renovate → agent) | ✅ detection live | [APP_UPDATES.md](APP_UPDATES.md) — all tags pinned, Renovate app installed + opening bump PRs (2026-07-17); lettabot triage layered later |
| Deploy primitive + admin-panel Deploy button (`main` → box) | 💭 specced, buildable | [DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md) — idempotent snapshot→apply→health-gate→rollback; three triggers (CLI/panel/agent); pull-only; closes the *merged-but-not-deployed* gap |
| Observability (Grafana/Loki) | 💭 not specced | TBD |

---

## Phase 2 — Second household

Triggered when a second household commits. Multi-tenancy decisions land here, plus
the first "shared admin" pressure.

| Item | Status | Doc |
| ---- | ------ | --- |
| Per-household Ente instances | 📋 specced in memory | TBD — promote the multi-tenancy design note |
| Member request portal (Jellyseerr) | 💭 identified, not specced | The *arr UIs conflate **configuring** (indexers, quality profiles, download clients — operator-only) with **requesting** (add a title — any member). That conflation is why "who are the *arr tools for?" feels murky. Answer: they're admin plumbing, and the member-facing tier is a separate request app. Three tiers: Jellyfin = consumption (public), Jellyseerr = requests (public + Pocket ID), *arr + qBittorrent = configuration (admin-plane/tailnet). Only becomes live with a second household — but note it changes the operation's character from "admin acquires for own household" to "co-op runs a request service", which is a deliberate decision, not a technical step |
| Pocket ID group scoping | 📋 partial in onboarding | [ONBOARDING.md](ONBOARDING.md) (extend) |
| Forward-auth on Caddy → Pocket ID | 📋 specced | [ADMIN_ACCESS.md](ADMIN_ACCESS.md#phase-2) |
| Admin agent (lettabot) | 📋 specced in memory | TBD — promote the admin agent design note to `ADMIN_AGENT.md` |
| Onboarding UX simplification | 💭 friction identified | TBD — see the onboarding constraint design note |
| Co-op host provisioning model | 📋 specced in memory | TBD — promote the provisioning design note |

---

## Phase 3 — Multi-host / product

Triggered by demand from a second co-op, or a clear hardware-product opportunity.
Mostly speculative today.

| Item | Status | Doc |
| ---- | ------ | --- |
| coralstack.org edge services | 💭 vision-stage | TBD |
| Self-hosted DNS + Handshake TLD | 💭 vision-stage | TBD |
| Install simplicity target (5 answers / 30 min) | 💭 north star | TBD — see the install simplicity target design note |
| Fleet release tags (hosts track `coralstack vX.Y.Z`, not `main`) | 💭 vision-stage | [DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md#5-the-release-concept--for-the-fleet-not-this-box) — `deploy(<tag>)` + a promote step, on the same primitive |
| Hardware product (HA-Green analogue) | 💭 vision-stage | TBD |

---

## Cross-cutting tracks

Work that doesn't belong to a single phase.

### Upstream contributions (spinoffs)
| Item | Status | Where |
| ---- | ------ | ----- |
| Vaultwarden Key Connector (standalone) | 📋 future spinoff repo | the key connector architecture design note |
| Ente CLI (`ente list`) | 🚧 dustindoan/ente fork | see [Related projects](#related-projects) |

### Positioning / strategy
| Item | Where |
| ---- | ----- |
| "Why not Nextcloud" framing | the Nextcloud comparison design note — promote to README FAQ when site copy lands |
| Open Home Foundation as reference / partner | the Open Home Foundation design note |
| Residential fibre / member-deployment tiers | the residential fibre capability design note |

---

## Related projects

**puddle** (`~/Dev/personal/puddle`, not yet published) — macOS menu-bar "Export
Drive" for the member-side photo migration (gate #1): an FSKit mount that
Photos.app exports into; writes flow to Ente and are deleted locally on confirmed
upload, with staging write-throttled at the syscall level. Extracted from
coralstack-ente-helper, which proved the pipeline end-to-end (2026-07-11: 956-item
migration day, 0 failures).

**[duckling](https://github.com/dustindoan/duckling)** — headless Ente client:
ente desktop's own upload/auth/crypto code compiled to a single binary. The upload
engine puddle supervises; also useful standalone against any museum.

**Ente CLI contribution (`ente list`)** — Go + Rust POCs validated (byte-parity on
a 31k-photo library); branches `feature/list-command` and `feature/list-command-rust`
on the dustindoan/ente fork; upstream discussion #10236 awaiting routing.

**Archived: coralstack-migrator** — the earlier Rust/osxphotos migration CLI+GUI,
superseded by puddle + duckling (2026-07-16). GitHub repo archived; do not resume.
Its planned `media` (music import) and `vault` (Vaultwarden import) modules have
no new home yet.

---

## Conventions

- **Status legend:** ✅ done · 🚧 in progress · 📋 specced (doc exists) · 💭 idea only
- **Memory → doc promotion:** when a memory note becomes load-bearing for >1 decision,
  promote it to a doc here and link from this roadmap. The memory entry stays as
  context; the doc becomes authoritative.
- **Adding a new service:** add a row under the Phase 1 service stack table, link to
  its compose file or in-progress branch.
