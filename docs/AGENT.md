# The agent — direction, ecosystem, and what to build first

> **Status (2026-09-03):** 💭 direction set, nothing built. This is the research
> and the decisions from the session that declared the Mac mini and specced
> Matrix. Read it before re-deriving any of it.
>
> Supersedes nothing; it *narrows* the admin-agent design note, which predates
> the Matrix decision and assumes Matrix only as a notification target.

## What the agent is actually for

Stated plainly by the user, and it's worth quoting the shape rather than
paraphrasing it: open a chat app, message the co-op's bot, and say *"update
yourself to Qwen 3.x"*, or *"share this photo with someone"*, or *"buy the
latest album and put it in Jellyfin."*

That is **two different agents** wearing one face:

| Role | Scope | Prior art in this repo |
| --- | --- | --- |
| **Admin / DevOps** | logs, restarts, updates, backups, drift | the admin-agent design note; [APP_UPDATES.md](APP_UPDATES.md) "where the AI agent fits" |
| **Concierge** | member-facing actions against the services | nothing — new |

The existing design note is entirely the first one. The concierge role is new as
of 2026-09-03 and has a materially worse risk profile, because its actions touch
member data and money rather than container state.

## Grade every proposed capability against what already exists

This is the most useful thing to come out of the discussion. Two of the three
examples were already solved or nearly so:

**"Update yourself to Qwen 3.9"** — already a primitive.
`host/mac-mini/ollama-reconcile.sh` does exactly this, and
[DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md) §2 already lists the agent as a
*trigger* alongside the CLI and the admin-panel button. The agent is a fourth
caller of an existing engine, not new machinery. **This is the right first job**
— narrow, high-frequency, already tested, and the blast radius is "AI chat is
down for a minute."

**"Buy the album, put it in Jellyfin"** — already built *except the purchase*.
`services/music/qobuz-poll.sh` → `qobuz-fetch.py` → music-ingest → Jellyfin runs
hands-off on a 15-minute timer today; buy something and it appears. So the only
step an agent adds is **spending money**, which is precisely the step that must
stay human. The agent's real contribution is a confirm prompt, not automation.

**"Share a photo with someone"** — the genuinely hard one, and the only example
that needs new design. Ente is end-to-end encrypted, so sharing requires the
account's keys, which are deliberately a Tier-2 Vaultwarden secret and
deliberately *not* SSO'd (see the Vaultwarden auth and Ente OIDC design notes).
**Standing agent custody of the photo vault's keys is a bigger trust decision
than anything in the existing Tier 3 list.** Don't fold it in as "another tool."

> The pattern to keep: before building an agent capability, check whether the
> underlying automation already exists. Often the agent's value is the
> *conversational surface*, not new plumbing underneath — and where it isn't,
> the missing piece is usually missing for a good reason.

## The ecosystem, as of 2026-09

People say "agent framework" for three separate layers. Conflating them is why
comparisons go in circles:

| Layer | Does | Candidates |
| --- | --- | --- |
| **Transport / gateway** | messaging channels ↔ agent, scheduling, notifications | OpenClaw; a thin bot you write |
| **Reasoning runtime** | the loop that plans and calls tools | **opencode**, Letta Code, Goose, OpenHands, raw Ollama tool-calling |
| **Memory** | what it knows next week | Letta (core + archival, pgvector) |

**opencode** is the strongest runtime candidate and was missing from the
original design note. It runs a real headless server — `opencode serve`,
OpenAPI 3.1, session create/fork/abort, basic auth via
`OPENCODE_SERVER_PASSWORD`, localhost-bound by default — so a gateway can drive
it programmatically. Ollama is first-class (`ollama launch opencode`). Crucially
it is *repo-shaped*, and so is the work: "update to Qwen 3.9" is edit
`models.txt`, open a PR, run the reconcile. That's a coding agent's native form.

**Letta** remains the memory answer (~23k stars, Ollama backend, Docker +
Postgres/pgvector). But consider first whether memory is actually needed:
**this repo's docs already are the institutional memory** — HARDWARE_FAILURE.md,
RECOVERY.md, the design notes, the incident writeups. A runtime that can read
them may need far less vector-store machinery than the 2026-04 design assumed.

### OpenClaw: useful, but read this first

OpenClaw is a self-hosted gateway bridging Signal, Matrix, WhatsApp, Telegram,
iMessage, Slack and more to an agent — which is genuinely the missing layer.
Its 2026 security record is the problem:

- **ClawJacked** (Oasis Security) — malicious websites could brute-force and
  hijack locally running instances and exfiltrate data. Patched 2026.2.26.
- **CVEs** — command injection (CVE-2026-24763), SSRF (CVE-2026-26322), path
  traversal (CVE-2026-26329), prompt-injection-driven RCE (CVE-2026-30741).
- **ClawHavoc** — a supply-chain campaign that put 1,100+ malicious "skills" on
  ClawHub disguised as productivity and coding tools.
- **Deployment reality** — of 42,000+ internet-exposed instances, 63% had the
  gateway port open with no authentication.

Treat exact figures as reported rather than verified; several sources are vendor
blogs, though IBM X-Force is credible and they agree. Three firm conclusions:

1. **Never install third-party skills.** Whatever tools it gets, you write.
2. **It does not go on the data path.** The mini is already a separate trust
   zone reaching the NUC through a restricted-shell SSH user. Keep that hard.
3. **It is the first inbound control channel into this network.** The Tier 3
   list and "the agent never pushes to main" stop being philosophy.

And the standing one: **indirect prompt injection is unsolved.** An agent that
reads Kuma alerts, GitHub issues and members' messages can be instructed by
anything it reads. That is the argument for the existing principle — the human
stays the final click permanently, and the win is the quality of the proposal.

## Why Matrix, and what changed

The channel question resolved into a service decision. See the Matrix design
note, `docs/MATRIX.md` (arrives with PR #65 — deliberately unmerged, because
deploying it creates three public vhosts). The short version: the agent needed a
channel,
Signal cannot be self-hosted, and Matrix can and federates — so the channel
became a co-op service and the agent became one of its users.

**Correction to the admin-agent design note:** it says "post to Matrix" meaning
a notification target. Matrix is now a first-class service in this stack with
its own homeserver, and the agent will have an account on it like any member.

## Build order

Each step is useful on its own and earns trust before the next.

1. **Outbound notifications only.** No agent, no reasoning, no inbound commands
   — a notify script the existing checks push to. **This closes a live hole:**
   `smart-check`, `drift-check` and `ollama-reconcile` all push to Uptime Kuma,
   and *no notification channel exists*, so they alert into the void. Worth
   doing whether or not the agent ever ships.
2. **Inbound read-only.** "Is everything up?" Queries, no actions.
3. **The update action.** Call `ollama-reconcile.sh` — already safe, already
   reports, already has a rollback story in that the mini doesn't matter.
4. **Triage of Renovate PRs.** See the backlog note below; this is the job with
   the clearest present-day value.
5. **Concierge actions.** Purchases behind a hard confirm. Ente only after the
   key-custody question has a real answer.

## The backlog that argues for step 4

As of 2026-09-03 there are **five Renovate PRs open, the oldest from
2026-07-17 — 48 days**. They include `timshel/oidcwarden` (the password manager,
labelled `stateful-review-carefully`) and `caddy` (the TLS boundary).

This is a **third** variant of the update gap, and the only one nothing watches:

| Variant | Status |
| --- | --- |
| merged but not deployed | caught by `services/drift/` |
| deployed but not merged | caught by `services/drift/` |
| **opened but not merged** | **nothing. 48 days.** |

It is the same shape as the Jellyfin security lag — detection worked, the human
gate stalled, and a security-relevant component sat behind. APP_UPDATES.md
predicted exactly this job for the agent: read the changelog, classify the risk,
summarize, escalate with a recommendation. It needs no autonomy to be useful.

## Open questions

- **Does memory earn its complexity?** Letta + Postgres + pgvector, versus a
  runtime that reads the repo's own docs. Decide before building.
- **Which runtime?** opencode's headless server is the strongest fit for
  repo-shaped work; letta-code was the original pick. They are not exclusive.
- **Gateway: OpenClaw or hand-rolled?** OpenClaw is more capability than a
  single-user admin bot needs, and its attack surface is the reason to hesitate.
  A Matrix bot that shells one command is a weekend and has no CVE history.
- **Ente key custody.** Unresolved and blocking the concierge role.

## Relationship to other docs

- The admin-agent design note — the tiers, sandbox and phase rollout still
  stand; this narrows the channel and runtime choices and adds the concierge role.
- `docs/MATRIX.md` (PR #65, unmerged) — the channel, now a service.
- [MAC_MINI.md](MAC_MINI.md) — where the agent runs, and the reconcile primitive
  that is its first job.
- [APP_UPDATES.md](APP_UPDATES.md) — predicted the triage role; the backlog above
  is the evidence.
- [DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md) — §2 already lists the agent
  as a trigger on the deploy primitive.
