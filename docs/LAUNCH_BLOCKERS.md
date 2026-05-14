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
- **Where it lives:** [coralstack-migrator](https://github.com/dustindoan/coralstack-migrator) (sibling repo). Mac-native CLI + GUI; Apple Photos → Ente pipeline.
- **Status:** in active development; previous-session branch on bundle ente-rs + require Download Originals.
- **Bar for "done":** one real iCloud library (~30k+ photos) migrated successfully from a member machine, with the result verified in Ente.

### 2. Music migration + acquisition path
"Replace Apple Music with Jellyfin" requires both (a) importing the existing library
and (b) telling members how to acquire new music going forward.
- **Migration:** future `media` module in coralstack-migrator (per its `lib.rs`). Not started.
- **Acquisition guidance:** documented recommendation — Bandcamp, Qobuz, ripping CDs, etc. Page or section on coralstack.org.
- **Bar for "done":** a member can rebuild their listening setup end-to-end with documented steps.

### 3. Backups (basic, present)
The pitch is "trust this with your family's photos and passwords." Without offsite
backups, one disk failure becomes a launch-killing story.
- **Strategy exists** in [memory: backup strategy](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_backup_strategy.md) (3-2-1, RAID ≠ backup, etc.).
- **Minimum viable implementation:** nightly restic → B2 (or equivalent) for:
  - Vaultwarden DB (`${DATA_PATH}/vaultwarden/`)
  - Ente postgres + minio (`${DATA_PATH}/ente-postgres/`, `${STORAGE_PATH}/ente-minio/`)
  - Pocket ID config + DB
  - Jellyfin config (not media — too large; document as "members keep originals")
- **Bar for "done":** one successful restore test from B2 to a fresh disk; runbook for the restore.

### 4. Member onboarding doc
[docs/ONBOARDING.md](ONBOARDING.md) is admin-facing (OIDC client wiring). There's no
"you, the community member, just got an email — here's how to install your apps and
set up your passkey" doc. Currently each admin writes this from scratch, per member.
- **What to write:** `docs/MEMBER_ONBOARDING.md` — Pocket ID passkey setup, Ente mobile install + login, Jellyfin client setup, Bitwarden client setup, "what to do when something doesn't work" (incognito test, contact admin).
- **Bar for "done":** non-technical household member walks through it unassisted, reaches working state in <30 min.

### 5. Public site (coralstack.org)
The single most leveraged blocker. Nothing else matters until people arrive.
- **At minimum:** landing page with the message, what's in/out comparison table, "interested? contact me" CTA, links to this repo + RoadMap.
- **Bar for "done":** the page exists, the message is clear, and someone arriving cold knows whether this is for them within 60 seconds.

### 6. External cold-install test
Has `setup.sh` been run start-to-finish by anyone other than the maintainer, on a clean Ubuntu box, without out-of-band guidance? If not, there are hidden problems.
- **What to do:** one external tester (a tech-comfortable friend) attempts the [QUICKSTART](QUICKSTART.md) on a fresh Ubuntu Server LTS VM, without help. Document where they get stuck.
- **Bar for "done":** the friend reaches a working stack, OR every blocker they hit is fixed in setup.sh / docs.

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
| **PWA failure-state caching** | "During transient outages, your browser may keep showing the failure after the server recovers. Try incognito or restart your browser." This recurring trust-erosion vector — see [memory note](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_pwa_failure_state.md). A `status.<dom>` page is the proper mitigation but is Phase 1.5 work. |
| **DNS / resilience caveats** | "We've explicitly diverged from common defaults where they bake-in single-failure assumptions. See [resilience pattern](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/feedback_resilience_vs_defaults.md)." |

## Open strategic questions

Items that need answers before site copy is final.

1. **Target audience definition.** Community organizers? Cooperative housing? Friend groups? Tech-savvy households? The site copy depends on which of these is primary.
2. **Pricing / model.** Free OSS only? Paid managed offering (CoralStack-as-a-Service)? Donations? Affects positioning and trademark posture.
3. **License posture.** coralstack-migrator is AGPL-3.0-only. coralstack-infra has no LICENSE file currently. What's the choice — AGPL, MIT, MPL? Worth deciding before public links.
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
