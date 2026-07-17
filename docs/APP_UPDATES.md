# Keeping services up to date — and the AI-agent question

> **Status (2026-07-17):** 🚧 step 0 complete. **Every** image tag is now
> pinned: the last floater, Ente, is digest-pinned in
> `services/ente/docker-compose.yml` now that the photo migration is verified
> (Ente ships only a rolling `:latest`, so a digest is the only real pin;
> Renovate is configured to open digest-bump PRs and treats Ente as
> stateful-review-carefully). Jellyfin `10.11.11` (clears the four advisories
> incl. the HIGH ffmpeg arg injection) is **deployed to the box** 2026-07-17,
> not just merged. `renovate.json` is in the repo root. **Remaining activation
> step:** install the Renovate GitHub App on `dustindoan/coralstack-infra`
> (https://github.com/apps/renovate) — hosted app chosen over self-hosted for
> now (open question 1): it only ever opens PRs against the repo (not a
> box/data-path service — see the note below); deploy stays manual-on-box, so
> sovereignty of the *data path* is unaffected.

> Original framing below. Frames how CoralStack
> should stay current without breaking a family's photo/password infrastructure,
> and where a local AI agent (lettabot) does and doesn't belong. Relates to the
> admin-agent vision in memory (`project_coralstack_admin_agent`) and the
> install-simplicity / self-management goals.

## The goal and the constraint

Stay current on **security and features**, but the stack holds members' photos,
passwords, and identity — a bad auto-update that corrupts a database or breaks
auth is a launch-killing trust event. So the bar is: **update routinely, but
never blindly, and never without a way back.** (We now have that way back —
[backups](BACKUPS.md) — which is a prerequisite for confident updating.)

## Current state (verified 2026-06-24)

Updates are **fully manual** today: bump the tag, `docker compose pull && up -d`,
eyeball health. The deploy path is the established **branch → PR → merge → `git
pull` on the apps VM**.

Version pinning is **inconsistent** — and that's the first thing to fix, because
PR-based updates require pinned, in-repo tags:

| Pinned ✅ | Floating ⚠️ (no/`latest` tag) |
|---|---|
| caddy `2.11.2-cloudflare`, gluetun `v3.41.1`, pocket-id `v2.5.0`, jellyfin `10.11.8`, postgres `15`, open-webui `v0.9.5`, oidcwarden `v2026.3.1-3` | **ente server + web** (`${ENTE_*_VERSION}=latest`), **`minio/minio`** (no tag), **`alpine/socat`** (no tag), **`dispatcharr:latest`** |

Floating tags are bad twice over: **not reproducible** (a rebuild can silently
change versions) and **not visible to an updater** (nothing to diff or PR).

## Step 0 (prerequisite): pin everything

Pin the four floaters to explicit versions. Caveat: **Ente is mid-migration on
`:latest`** — pin it *after* the migration completes so the server doesn't change
under an active upload. minio/socat/dispatcharr can be pinned anytime. This is a
small, high-value PR and the foundation for everything below.

## Detection & update strategies

| Tool | What it does | Fit |
|---|---|---|
| **Renovate** | Watches image tags in compose files, opens **PRs** to bump them (with changelog links) | ✅ **Best fit** — slots directly into the existing branch→PR→merge→deploy flow; human stays in control |
| Diun / What's-Up-Docker | Notify-only (new tag available) | OK lightweight alternative; no PR, you act manually |
| **Watchtower** | Auto-pulls + restarts containers | ❌ **Not for this stack** — blind auto-restart of stateful services (Vaultwarden, Ente/Postgres) risks a bad release or mid-migration corruption |

**Recommendation:** Renovate (hosted GitHub app or self-hosted) opening bump PRs
into this repo, reviewed and deployed the same way everything else is. Optionally
Diun for images not managed in the repo.

## Risk tiers (this is the judgment the update flow must encode)

Not all updates are equal. The flow should classify and route:

- **Patch / security bumps** (e.g. `10.11.8 → 10.11.9`) — low risk; candidates for
  fast-track / eventual auto-merge after health checks.
- **Minor versions** — review changelog; usually safe; deploy + verify.
- **Major versions & anything with a DB migration** (Ente, Postgres, Vaultwarden
  especially) — **always human-gated**: read release notes, **back up first**,
  expect schema migrations, have a rollback plan. Never fast-track these.

## Where the AI agent fits (and where it doesn't)

This is the natural, *bounded* first job for **lettabot** (the planned Mac-mini
admin agent — see `project_coralstack_admin_agent`: Phase 1B observation-only →
Phase 2 autonomous with approval gates). Update management is a great first task
because it's narrow, high-frequency, and has a clear safety envelope.

**Renovate detects; the agent judges.** The toil that's left after Renovate opens
a PR is exactly what an agent is good at:
- Read the changelog / release notes for the bump.
- Classify risk (patch vs major, presence of DB migrations / breaking changes).
- For low-risk: optionally auto-merge after CI/health checks pass.
- For risky: summarize the changelog + migration steps and **escalate to the
  admin** with a recommendation (approval gate).
- After deploy: verify health (containers up, endpoints responding); **roll back
  on failure** — with the backup as the ultimate safety net.

**Where it does *not* belong (yet):** blind auto-application of major/stateful
updates; anything touching Ente/Postgres/Vaultwarden schemas without a human.
Those stay gated regardless of agent maturity.

**Phase-appropriate path:** start with **Renovate + human** (works today, no
agent needed). Design that flow so the triage/verify/rollback role is a clean
seam an agent can occupy later — i.e. the agent *augments* the PR flow, it
doesn't replace the safety rails.

## Safety rails (must exist before any automation)

1. **Pinned versions** (step 0) — reproducible, diffable.
2. **Backups before stateful updates** — now in place ([BACKUPS.md](BACKUPS.md)).
3. **Health verification** — a check the flow (or agent) runs post-deploy:
   containers healthy + key endpoints 200. *This harness doesn't exist yet* and
   is a dependency for any auto-merge.
4. **Approval gates** — major/stateful updates require explicit human sign-off.
5. **Rollback plan** — re-pin to the previous tag + `up -d`; restore DB from
   backup if a migration ran.

## Open questions for the next session

1. **Renovate hosted vs self-hosted?** (Self-hosted keeps it in-sovereignty;
   hosted is zero-maintenance.)
2. **Which updates may ever auto-merge** vs always human-gated? (Propose: patch
   bumps of stateless services auto after health checks; everything else gated.)
3. **Build the health-check harness** — what's "healthy" per service, and how is
   it asserted? (Prerequisite for auto-merge and for agent rollback decisions.)
4. **Agent timing** — is lettabot far enough along to take the triage role, or is
   this a "Renovate now, agent later" two-phase rollout? (Likely the latter.)
5. **CI for this repo** — there is none today; even a lint/compose-validate +
   health-smoke on PRs would make update PRs safe to act on.

## Recommended first step

Two small, independent moves that need no agent — **both done**:
1. ✅ **Pin the four floating tags** — minio/socat/dispatcharr pinned; Ente
   digest-pinned post-migration (2026-07-17). Reproducibility gap closed.
2. ✅ **Add a `renovate.json`** scoped to the service compose files so update PRs
   flow into the existing review process. (Awaiting the GitHub App install to
   activate — see status note at top.)

The AI-agent layer is then a *later* enhancement that plugs into that PR flow as
lettabot matures — not a prerequisite, and explicitly out of scope until the
health-check harness and approval gates exist.
