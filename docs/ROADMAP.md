# Roadmap

What's planned, what's in flight, and what's deferred — for the **coralstack-infra**
repo specifically. The companion roadmap for the member-side migration tool lives in
[coralstack-migrator](#related-projects).

This doc is an **index**, not a substance doc. Each work item links to a spec, runbook,
or open question. If a row says "TBD" in the doc column, the thinking exists (often in
session memory) but hasn't been written down yet — capture it before you build it.

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
[memory: trial state expendable](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_trial_state_expendable.md).
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
| Open WebUI | ✅ deployed (Ollama on Mac mini) | [PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) Phase 4c |
| TubeArchivist | 🚧 in progress | (this branch) |

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
| Power-loss recovery | ✅ runbook complete | [RECOVERY.md](RECOVERY.md) |
| Secret tiering (Tier 1 paper / Tier 2 vault) | ✅ convention | [ADMIN_ACCESS.md](ADMIN_ACCESS.md#secret-tiers) |

---

## Phase 1.5 — Friction-driven maturity

Triggered when SSH-tunnel admin gets annoying, or when "Jellyfin lost my watch progress
again" makes backups non-negotiable.

| Item | Status | Doc |
| ---- | ------ | --- |
| Headscale (self-hosted tailnet) | 📋 specced | [HEADSCALE.md](HEADSCALE.md) |
| Backup strategy implementation | 📋 specced in memory | TBD — promote [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_backup_strategy.md) to `BACKUPS.md` |
| Observability (Grafana/Loki) | 💭 not specced | TBD |

---

## Phase 2 — Second household

Triggered when a second household commits. Multi-tenancy decisions land here, plus
the first "shared admin" pressure.

| Item | Status | Doc |
| ---- | ------ | --- |
| Per-household Ente instances | 📋 specced in memory | TBD — promote [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_multitenancy.md) |
| Pocket ID group scoping | 📋 partial in onboarding | [ONBOARDING.md](ONBOARDING.md) (extend) |
| Forward-auth on Caddy → Pocket ID | 📋 specced | [ADMIN_ACCESS.md](ADMIN_ACCESS.md#phase-2) |
| Admin agent (lettabot) | 📋 specced in memory | TBD — promote [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_admin_agent.md) to `ADMIN_AGENT.md` |
| Onboarding UX simplification | 💭 friction identified | TBD — see [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_onboarding_constraint.md) |
| Co-op host provisioning model | 📋 specced in memory | TBD — promote [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_provisioning.md) |

---

## Phase 3 — Multi-host / product

Triggered by demand from a second co-op, or a clear hardware-product opportunity.
Mostly speculative today.

| Item | Status | Doc |
| ---- | ------ | --- |
| coralstack.org edge services | 💭 vision-stage | TBD |
| Self-hosted DNS + Handshake TLD | 💭 vision-stage | TBD |
| Install simplicity target (5 answers / 30 min) | 💭 north star | TBD — see [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_install_simplicity_target.md) |
| Hardware product (HA-Green analogue) | 💭 vision-stage | TBD |

---

## Cross-cutting tracks

Work that doesn't belong to a single phase.

### Upstream contributions (spinoffs)
| Item | Status | Where |
| ---- | ------ | ----- |
| Vaultwarden Key Connector (standalone) | 📋 future spinoff repo | [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_key_connector_architecture.md) |
| Ente CLI (`ente list`) | 🚧 dustindoan/ente fork | tracked in [coralstack-migrator](#related-projects) |

### Positioning / strategy
| Item | Where |
| ---- | ----- |
| "Why not Nextcloud" framing | [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_nextcloud_comparison.md) — promote to README FAQ when site copy lands |
| Open Home Foundation as reference / partner | [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_open_home_foundation_reference.md) |
| Residential fibre / member-deployment tiers | [memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_residential_fibre_capability.md) |

---

## Related projects

**[coralstack-migrator](https://github.com/dustindoan/coralstack-migrator)** — Mac-native
member-side onboarding tool (Rust workspace, CLI + GUI). Apple Photos → Ente today;
`media` (Jellyfin music import) and `vault` (Vaultwarden import) modules planned as
sibling subsystems. That repo owns:

- Photo migration architecture (Takeout sidecars, icloudpd-on-Linux pattern)
- Ente CLI upstream contribution (Go + Rust POCs)
- Future Jellyfin music import (`media` subsystem)
- Future Vaultwarden import (`vault` subsystem)

Cross-link target: `coralstack-migrator/docs/ROADMAP.md` (to be created).

---

## Conventions

- **Status legend:** ✅ done · 🚧 in progress · 📋 specced (doc exists) · 💭 idea only
- **Memory → doc promotion:** when a memory note becomes load-bearing for >1 decision,
  promote it to a doc here and link from this roadmap. The memory entry stays as
  context; the doc becomes authoritative.
- **Adding a new service:** add a row under the Phase 1 service stack table, link to
  its compose file or in-progress branch.
