# Deploy architecture — how `main` reaches the box

> **Status (2026-07-17):** 💭 specced, not built. The primitive below does not
> exist yet; today's deploy is still hand-run `git pull && docker compose up -d`
> on the box (see [memory: deploy workflow](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_deploy_workflow.md)).
> This doc is the target and the build plan. Prerequisite —
> [backups](BACKUPS.md) — is now met, which is what makes a *safe* deploy button
> possible at all.

## The problem this solves

[APP_UPDATES.md](APP_UPDATES.md) closed the *detection* half of staying current:
[Renovate](https://github.com/apps/renovate) watches the pinned image tags and
opens bump PRs into the repo. But detection only reaches `main`. Two gaps remain
between "a newer image exists" and "members are running it", and **nothing
automates either today**:

```
 Renovate            You                     ??? (manual, by hand)
 ─────────           ─────────               ─────────────────────
 watches image   →   review + merge      →   ssh box; git pull;
 tags in repo        the PR to main          docker compose pull; up -d
 opens a PR          (GitHub)                (the RUNNING container changes)
    gap 1: nothing builds/releases    gap 2: nothing deploys to the box
```

- **Renovate creates no releases and no images.** It edits a tag *string* in a
  compose file. The images themselves are built and published by *upstream*
  (Jellyfin, Ente, …); Renovate just notices newer ones exist. There is no
  "build" step to automate — 90% of the stack is upstream images, and the few
  custom images (caddy, admin-panel, backup, ente-janitor) build *on the box* at
  `compose up --build`.
- **Nothing propagates `main` → box.** Merging a PR changes GitHub, not
  coralstack-apps. The box only changes when a human SSHes in and pulls. Merge
  and deploy are two separate acts, and **only the first is visible on GitHub** —
  which is exactly how the box silently ran an old Jellyfin (advisory-carrying
  10.11.8) for days after 10.11.11 was merged. See the *merged-but-not-deployed*
  pattern; it recurred three times in one week (admin-panel, backup, jellyfin).

The word people reach for — "a release that gets installed" — maps onto **none**
of these steps. The right framing is: Renovate automates *noticing*; a human
automates *nothing* past the merge button; the box deploy is hands-on. This doc
makes the second gap a first-class, observable, gated operation.

## Design

### 1. One idempotent deploy primitive

The foundation is a single operation — *reconcile this box to a given git ref* —
that everything else merely triggers:

```
deploy(ref):
  git fetch
  preflight:  render `docker compose config` for the target ref; refuse on error
  snapshot:   if any stateful service (ente/vaultwarden/pocket-id/postgres) will
              change, run backup.sh FIRST (a way back — see BACKUPS.md)
  apply:      git checkout <ref>; docker compose pull; docker compose up -d --build
  verify:     per-service health check (see APP_UPDATES.md open question 3)
  on failure: roll back to the previous ref + `up -d`; report loudly
  report:     what changed (image diffs), health result, new box ref
```

Properties that matter:

- **Idempotent** — re-running when already at `ref` is a no-op. Safe to retry.
- **Snapshot-before-stateful** — the deploy is only as safe as the way back. This
  is *why* backups were a hard prerequisite, not a nice-to-have.
- **Health-gated + auto-rollback** — a deploy that leaves a service unhealthy
  rolls itself back rather than leaving members on a broken stack.
- **Honors the `.env` gotcha** — gitignored `services/*/.env` files do **not**
  travel with a pull. The primitive must detect a service whose compose gained a
  required env var with no matching `.env` on the box and *refuse with a clear
  message*, not bring it up half-configured. (See [memory: deploy workflow](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_deploy_workflow.md).)

Everything below is a *trigger* for this one primitive. Build it once.

### 2. Three triggers, one engine

| Trigger | Who | When |
| --- | --- | --- |
| **CLI** — `coralstack deploy [ref]` | admin at a shell | scripted / power use; the `setup`+`doctor` CLI grows this verb |
| **Admin-panel button** | admin in the loopback panel | the everyday human path — see below |
| **lettabot** (later) | the admin agent | autonomous, within approval gates — the Phase 2 [admin agent](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_admin_agent.md) |

The insight: the admin-panel button is **both** the endgame surface for the
human-operated tier **and** the manual precursor to autonomous ops. Same engine
underneath all three — which is why the primitive comes first and the surfaces
are thin.

### 3. Two gates, two surfaces — don't merge them

"An update is available" is really two distinct states, and conflating them is a
trap:

| State | Meaning | Action | Lives on |
| --- | --- | --- | --- |
| Available upstream, **not merged** | Renovate PR open | **review + merge** (read changelog, judge risk) | **GitHub** |
| Merged to `main`, **not on box** | box is N commits behind | **deploy** | **admin panel** |

The **merge gate stays on GitHub** — that's where the diff, changelog links,
`stateful-review-carefully` label, and review thread already live. Do **not**
rebuild PR review inside the panel. The **deploy gate lives on the panel**: it
surfaces drift ("`main` is 2 commits ahead, including: oidcwarden 2026.3→2026.6,
socat 1.8.0→1.8.1") and offers a confirm-gated **Deploy** button — same
confirm-gate pattern as the existing "Expedite deletion queue" button.

### 4. Pull, never push — a sovereignty line, not a preference

The box **pulls** from GitHub; GitHub must never reach *into* the box.

A GitHub Actions job that SSHes in to deploy would hand GitHub a write credential
to the host holding members' photos and passwords — the same anti-pattern as
running Renovate on the box. So: **no CD that pushes.** The box (via the panel
button, the CLI, or eventually lettabot) polls `main` and applies locally. This
is the same principle that keeps Renovate a GitHub App acting on the *repo*, and
keeps CI off the box: **the data-path host stays a pure pull consumer.**

### 5. The "release" concept — for the fleet, not this box

The instinct to "version the whole stack as a releasable artifact" is right, but
it's **git tags of the infra repo**, not a package manager, and it belongs to the
multi-host future:

- **Single box (Phase 1–2):** the box tracks `main` (or a chosen ref). Fine.
- **Multiple co-ops (Phase 3):** you do *not* want every host on `main` HEAD.
  Each host tracks a tested tag — `coralstack v1.4.0` — a known-good full-stack
  state. You promote `main → v1.4.0` when it's proven on your own box first, and
  fleet hosts deploy to the tag. That is the "release," realized as
  `deploy(v1.4.0)` on the same primitive. It needs no code until the second
  household exists.

## The one caution

A one-click **Update** button is safe for stateless / config bumps (caddy,
jellyfin, socat) and genuinely dangerous for the stateful three (Vaultwarden,
Ente, Postgres) *if it erodes discipline*. The button must still **work** for
them — but only through snapshot-first + health-gate + the same
`stateful-review-carefully` friction the merge gate enforces. Don't let one-click
convenience quietly turn a Postgres major into a rubber-stamp. (Postgres majors
are already `enabled: false` in Renovate — they need a dump/restore migration,
not a tag bump; the deploy primitive should refuse them outright.)

## Build plan

This is buildable now, in increments, each independently useful:

1. **`coralstack deploy` primitive + CLI** (the whole of §1 as a script on the
   box). Immediately replaces hand-run `git pull && up -d` and gives
   snapshot-before + health-gate + rollback for free. Highest value, no UI.
2. **Drift read-out in the admin panel** — "box ref vs `main`, with the image
   diffs between them." Read-only; this alone kills the *merged-but-not-deployed*
   blind spot. Pairs with the `doctor` running-vs-pinned check.
3. **The Deploy button** — confirm-gated call into the §1 primitive, from the
   loopback panel. The everyday human path.
4. **Health-check harness** — formalize "what is healthy per service" (APP_UPDATES
   open question 3). Prerequisite for trustworthy auto-rollback *and* for any
   later autonomy.
5. **lettabot trigger** (Phase 2) — the agent calls the same primitive within
   approval gates. No new deploy logic, just a new caller.
6. **Fleet tags** (Phase 3) — `deploy(<tag>)` + a promote step. Only when a second
   host exists.

Steps 1–3 are a natural next project after launch; they share the `setup`/`doctor`
CLI substrate (the "verify the boundary" tool from the config-classes discussion)
and the admin-panel action surface already shipped for the Ente deletion queue.

## Relationship to other docs

- [APP_UPDATES.md](APP_UPDATES.md) — the *detection* half (Renovate). This doc is
  the *deployment* half. Together they're the full update loop.
- [BACKUPS.md](BACKUPS.md) — the way back. Hard prerequisite for a safe deploy
  primitive.
- [admin agent memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_admin_agent.md) —
  lettabot is the eventual autonomous trigger; this primitive is what it calls.
- [deploy workflow memory](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_deploy_workflow.md) —
  the current manual mechanism this replaces, and the `.env` gotcha the primitive
  must honor.
