# Launch blockers

What's between us and a public message that says *"self-host, host for your community"* —
shipped on [coralstack.org](https://coralstack.org), with early co-ops invited to try
it under realistic expectations.

This doc is **tactical and time-bound** — it exists until launch, then gets archived
or transformed into a retrospective. The [ROADMAP](ROADMAP.md) remains the long-term
index; this doc is the short-term punch list.

## The launch we're shipping

Not: *"production-ready self-hosting platform for any community."*

Yes: *"early-stage cooperative self-hosting infrastructure — here's what works, here's
what doesn't, contact the maintainer before you try it."*

This framing is deliberate. Most of the actual blockers below are blockers for the
larger "production for any community" launch. For the "early-stage, talk to us" launch,
many items downgrade from gates to honest-disclosure on the site.

Audience for v1: **community organizers, tech-comfortable households, cooperative
housing, friend groups** — people who appreciate transparency about rough edges and
will tolerate them in exchange for sovereignty.

## Hard gates (must complete before public link)

Items that, if missing, break the value proposition or risk member trust.

### 1. Photos migration end-to-end
The pitch is "replace iCloud Photos with Ente." Without a working migration path,
members can't actually switch — the data lives in iCloud, leaving is too painful.
- **Where it lives:** **puddle** (`~/Dev/personal/puddle`, not yet published) — a macOS
  menu-bar "Export Drive": an FSKit mount that Photos.app's "Export Unmodified Originals"
  writes into, with uploads to Ente (and delete-on-confirm) driven by
  [duckling](https://github.com/dustindoan/duckling), a headless build of ente
  desktop's own upload engine. *(The earlier coralstack-migrator / osxphotos Rust
  tool is archived — superseded, do not resume.)*
- **Status:** pipeline proven end-to-end 2026-07-11 via puddle's predecessor
  (coralstack-ente-helper): 956-item migration day, 0 failures. Remaining: validate
  puddle as a shipped .app bundle (first-run FSKit enablement per
  `puddle/docs/operations.md`) + one real full-library run through it.
- **Bar for "done":** one real iCloud library (~30k+ photos) migrated successfully from a member machine, with the result verified in Ente.

### 2. Music migration + acquisition path
"Replace Apple Music with Jellyfin" requires both (a) importing the existing library
and (b) telling members how to acquire new music going forward.
- **Migration:** a future member-side music import tool. Not started, and currently
  homeless — it was planned as coralstack-migrator's `media` module, but that repo is
  archived; a new home (possibly alongside puddle/duckling) is TBD.
- **Acquisition guidance:** documented recommendation — Bandcamp, Qobuz, ripping CDs, etc. Page or section on coralstack.org.
- **Design / hand-off:** [docs/MUSIC_ACQUISITION.md](MUSIC_ACQUISITION.md) — the
  purchase → ingest → Jellyfin pipeline ("buy an album on-the-go, it appears in
  the collection"), options, and the buy-&-own vs auto-grab decision.
- **Bar for "done":** a member can rebuild their listening setup end-to-end with documented steps.

### 3. Backups (basic, present) — ✅ done 2026-07-17; photo restore proven byte-identical from B2
The pitch is "trust this with your family's photos and passwords." Without offsite
backups, one disk failure becomes a launch-killing story.
- **Strategy exists** in [memory: backup strategy](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_backup_strategy.md) (3-2-1, RAID ≠ backup, etc.).
- **Implemented:** [services/backup](../services/backup/) — `restic` + `rclone`,
  scheduled nightly. Consistent DB dumps (Ente `pg_dump`, Vaultwarden + Pocket ID
  SQLite `.backup`) + one whole-tree snapshot of `${DATA_PATH}` and `${STORAGE_PATH}`
  (photos always; music excluded by default as re-acquirable). **Cloud-agnostic**:
  the destination is a pure env knob (local path, or `rclone:` → B2/Wasabi/R2/SFTP/
  a co-op member's box) — no vendor lock-in, opaque encrypted blobs only. Runbook:
  [docs/BACKUPS.md](BACKUPS.md).
- **Bar for "done":** one successful restore test from the repo. ✅ **Met
  2026-07-17.** Procedure is in [BACKUPS.md → Restore test](BACKUPS.md#restore-test-the-gate).
- **2026-07-15 restore test** caught a critical coverage gap (the deployed
  `BACKUP_EXCLUDES` excluded all of `/storage`, so Ente photo blobs had never
  been in any snapshot) — now closed.
- **2026-07-17: gate met.** Corrected excludes + split-stream retention deployed;
  the [Ente purge-queue drain](ENTE_STORAGE.md) cut the seed from ~646 GB to
  ~242 GB, then the initial seed uploaded both streams to B2 (`data` 2.581 GiB +
  `storage` 242.800 GiB, `restic check` clean). **Blob restore proven:** a real
  ~1.7 GB multipart photo restored byte-identical from B2 (sha256 match to the
  live original). The "restore-tested backups" site claim is now literally true.
  See [BACKUPS.md → Restore-test log](BACKUPS.md#restore-test-log).

### 4. Member onboarding doc — 🚧 doc written 2026-07-15; walkthrough test pending
[docs/ONBOARDING.md](ONBOARDING.md) is admin-facing (OIDC client wiring). Members
need a "you just got an invite — here's how to set up your apps" doc.
- **Written:** [docs/MEMBER_ONBOARDING.md](MEMBER_ONBOARDING.md) — passkey setup,
  Bitwarden clients (self-hosted URL gotcha), Ente signup + mobile, Jellyfin
  clients via Quick Connect, AI chat, "when something looks broken" (status page →
  incognito → admin). Admin prep prerequisites are in its top note (incl. enabling
  Jellyfin Quick Connect, which native-app SSO sign-in depends on).
- **Bar for "done":** non-technical household member walks through it unassisted, reaches working state in <30 min. Not yet tested — run it with the next real onboarding and log where they stall.

### 5. Public site (coralstack.org) — 🚧 copy drafted 2026-07-15
The single most leveraged blocker. Nothing else matters until people arrive.
- **At minimum:** landing page with the message, what's in/out comparison table, "interested? contact me" CTA, links to this repo + RoadMap.
- **Drafted:** [docs/SITE_COPY.md](SITE_COPY.md) — full page copy with the three
  strategic decisions baked in (member-first voice, free-OSS + contact-me, Live
  TV omitted). Includes a pre-publish checklist and a claims audit (don't
  publish "restore-tested" before the initial photo backup runs).
- **Built 2026-07-15:** [site/index.html](../site/index.html) — single static
  page, deployed by `.github/workflows/pages.yml` (inert until Pages is enabled
  in repo settings). Contact CTA: dustindoan@proton.me. Publish procedure:
  [site/README.md](../site/README.md).
- **Remaining:** enable GitHub Pages + coralstack.org DNS (admin, per
  site/README.md) — **only after SEC-1 + the initial photo backup**.
- **Bar for "done":** the page exists, the message is clear, and someone arriving cold knows whether this is for them within 60 seconds.

### 6. External cold-install test
Has `setup.sh` been run start-to-finish by anyone other than the maintainer, on a clean Ubuntu box, without out-of-band guidance? If not, there are hidden problems.
- **What to do:** one external tester (a tech-comfortable friend) attempts the [QUICKSTART](QUICKSTART.md) on a fresh Ubuntu Server LTS VM, without help. Document where they get stuck.
- **Bar for "done":** the friend reaches a working stack, OR every blocker they hit is fixed in setup.sh / docs.

### 7. Pre-launch security pass — ✅ run 2026-07-15; SEC-1 remediated + re-verified 2026-07-16
Point-in-time review of the externally reachable surface + a git-history secrets
audit. Full results: [docs/SECURITY_PASS.md](SECURITY_PASS.md).
- **Clean:** git history (gitleaks, 57 commits), published ports (only Caddy 443;
  Dispatcharr is localhost-only), per-service auth (every exposed vhost
  self-authenticates), Vaultwarden invite-only.
- **SEC-1 (HIGH): ✅ remediated + re-verified 2026-07-16.** Was: open recursive
  DNS resolver on the WAN IP. Fixed at three layers (Unbound WAN listener
  removed, internal-only ACLs, offending WAN pass rule deleted — a
  source-restricted rule defeated by upstream-NAT source rewriting; see the
  remediation log in SECURITY_PASS.md). Off-net `dig` now times out.
- **Dispatcharr public story:** ✅ decided 2026-07-15 — **omitted from the
  public site entirely.** The site's feature story is photos / passwords /
  media / AI; Live TV stays un-marketed (repo remains public as-is).
- **Bar for "done":** SEC-1 remediated and re-verified from off-net. ✅ Met 2026-07-16.

## Honest-disclosure items (acknowledged, not gates)

Items that don't block launch *if* the public site is transparent about them. Silence
is worse than acknowledgment.

| Item | Disclosure shape |
|------|------------------|
| **Contacts / Calendar gap** | "We don't replace iCloud Contacts / Calendar yet. Recommended: keep using iCloud, or run [Baikal/Radicale] yourself." |
| **File sync (iCloud Drive) gap** | "Not yet replaced. Recommended: Syncthing or Seafile if you need this, or keep iCloud Drive." |
| **Hardware-death recovery** | "Power loss is documented (see RECOVERY.md). Full hardware replacement requires backups (gate #3) + fresh host install." |
| **Single-host SPOF (Phase 1)** | "Phase 1 deployments run router + apps on one machine. Recommended for production: separate firewall hardware (see ROADMAP)." |
| **Onboarding is high-touch (2-3 hrs per member)** | Acknowledge directly; targeted at communities where this fits the value. See [memory: onboarding UX constraint](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_onboarding_constraint.md). |
| **PWA failure-state caching** | "During transient outages, your browser may keep showing the failure after the server recovers. Check **status.<domain>** to see whether it's actually back, then restart your browser / try incognito." The `status.<domain>` page (Uptime Kuma) is now in the repo ([services/uptime-kuma](../services/uptime-kuma/docker-compose.yml)) — deploy pending. Background: [memory note](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_pwa_failure_state.md). |
| **DNS / resilience caveats** | "We've explicitly diverged from common defaults where they bake-in single-failure assumptions. See [resilience pattern](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/feedback_resilience_vs_defaults.md)." |

## Open strategic questions

Items that need answers before site copy is final.

1. **Target audience definition.** ✅ Decided 2026-07-15: the **member/consumer is the primary reader** — the person whose photos and passwords move; host-admins are the secondary audience ("run one for your people"). Voice reference: the maintainer's 2026-06-11 "exits are closing" message (Photos API deprecation, cloud concentration, AI switching costs → sovereignty).
2. **Pricing / model.** ✅ Decided 2026-07-15: **free OSS + "contact me."** No pricing page, no billing signals; invite-only trials via direct contact. Managed offering deliberately deferred, not foreclosed.
3. **License posture.** ✅ Decided: AGPL-3.0-only ([LICENSE](../LICENSE), PR #13), matching the (since-archived) coralstack-migrator.
4. **Phase 1 → Phase 2 promotion criteria.** When do you tell a second co-op "yes, you can host this safely"? What's the explicit checklist? Today's framing is "talk to me first" — but at some point that doesn't scale.
5. **Trademark / branding considerations.** coralstack.org owned. Name distinct enough not to clash? Any concerns to surface before public?

## Tracking conventions

- ✅ done — link to a commit, doc, or external artifact
- 🚧 in progress — link to the branch/repo
- 📋 specced — link to the design doc
- 💭 idea only — no spec yet

Cross off here as items land. When all gates are checked, the launch is unblocked.

## What this doc captures from today's thinking

This doc is the working artifact for the strategic chat that emerged from a longer
session about TubeArchivist, admin-plane spec, and a DNS cascade outage. Two findings
from that session inform the items here:

- **PWA failure-state persistence** (added as honest-disclosure item; recommends `status.<dom>` as Phase 1.5)
- **The resilience-vs-defaults pattern** — we're explicitly diverging from defaults that target typical home use; that divergence is worth surfacing on the site rather than hiding it
