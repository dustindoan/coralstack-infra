# The Mac mini — the host outside the deploy model

> **Status (2026-09-03):** 🚧 declaration landed, nothing installed on the box
> yet. `host/mac-mini/` now holds the mini's desired state as code; the
> reconcile script and its launchd timer are written but **not yet installed**
> on the mini, and Ollama there is still 0.30.10. See
> [Build plan](#build-plan) for what's done and what isn't.

## Why this doc exists

[DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md) describes how `main` reaches
"the box" — singular. But CoralStack runs on **two** machines, and only one of
them is in that model:

| Host | What it runs | In the deploy model? |
| --- | --- | --- |
| NUC (Proxmox → apps VM) | the whole Docker Compose stack | ✅ pinned tags, Renovate, drift-check, `git pull` |
| **Mac mini** | Ollama — inference for Open WebUI | ❌ **nothing** |

Before this doc, the mini appeared in the repo exactly twice: as an IP address
(`MAC_MINI_IP`, consumed by `services/open-webui/docker-compose.yml`) and as
prose in Phase 4c of [PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md). Renovate
could not see it. The deploy primitive would not touch it. `services/drift/`
does not watch it. It was **documented, not declared** — and those are very
different things.

### The incident that surfaced it

2026-09-03: a request to add a new model (`qwen3.8:27b-nvfp4`) to the mini
failed. Not because the model was wrong or the disk was full — 818 GB free —
but because the mini's Ollama was **0.30.10, a June build, three minor versions
behind**, and the registry refuses to serve current models to a client that old.
The pull exited `0` after printing only *"Please download the latest version"*.

The cause is structural, not an oversight. The Ollama Mac app updates itself by
downloading in the background and then asking a human to click **"Restart to
update"** in the menu bar. The mini is **headless with auto-login** — that click
will never happen. Its updater had in fact created an empty update slot at
`~/Library/Caches/ollama/updates/` that same day and stalled there. On this box
the vendor's update mechanism *cannot succeed*, and nothing was watching it fail.

That is the same shape as the *merged-but-not-deployed* pattern the NUC hit
three times in one week — a silent gap between "a newer version exists" and
"the box runs it" — except the mini had no detection layer at all.

## Three undeclared things

The failure hit all three at once, and they need different treatment:

| What | Was | Now declared in | Risk if wrong |
| --- | --- | --- | --- |
| **Ollama version** | unpinned, GUI-gated updater | `host/mac-mini/versions.env` | app restart; chat down ~1 min |
| **Model set** | undeclared — `qwen3.6:27b-nvfp4` was on the box because someone typed it once | `host/mac-mini/models.txt` | disk fill; a pull is otherwise harmless |
| **Host config** (LaunchAgent, five `OLLAMA_*` env vars) | prose in a runbook | `host/mac-mini/com.ollama.host.{sh,plist}` | binds loopback-only → Open WebUI can't reach it |

The host config was the easiest win and mostly transcription: the script and
plist were already written verbatim in PROXMOX_MIGRATION.md Phase 4c. Moving
them into the repo means a rebuild is `install.sh`, not a copy-paste session,
and a hand-edit on the box becomes drift something can notice.

## The inversion: the mini is the safe place to rehearse

[APP_UPDATES.md](APP_UPDATES.md) gates updates hard, and it is right to — the
NUC holds members' photos, passwords, and identity, so `renovate.json` sets
`automerge: false` everywhere and deploy stays a deliberate human act.

The mini is the exact opposite. [HARDWARE_FAILURE.md](HARDWARE_FAILURE.md)
already grades it:

> Mac mini — AI chat only. Everything else survives. Graceful degradation —
> nothing else depends on it.

**It is the one host where a bad update costs nothing.** No member data lives on
it; no other service depends on it; its blast radius is "Open WebUI can't chat
for a few minutes." That makes it the natural place to prove the autonomous
update loop — reconcile, verify, report, alert on failure — *before* that
machinery is ever pointed at Vaultwarden.

So the risk tiering inverts here, deliberately:

| Action | On the NUC | On the mini |
| --- | --- | --- |
| Pull a new model / image | human-gated merge + manual deploy | **auto-applied** — additive, reversible, cheap |
| Upgrade the runtime (Ollama app / stateful service) | human-gated | **report + alert only** — needs a binary swap, so a human decides |
| Remove something | human-gated | **never automatic** — `--prune` is a manual verb |

### Why removal is never automatic

`ollama rm` on a 17 GB model is fast to run and slow to undo — a re-pull is a
17 GB download over a residential link. Worse, "undeclared" is a weak signal: a
model can be absent from `models.txt` because it was retired, or because someone
is mid-experiment and hasn't committed yet. The reconcile script therefore
**reports** undeclared models and leaves them alone. Pruning is a human verb.

### Why the Ollama upgrade is not automatic

Applying it means downloading a ~187 MB zip and replacing `/Applications/
Ollama.app` — swapping an application binary on a running host. That is a
categorically different act from `ollama pull`, and it is not one a timer should
perform unattended. Renovate will open a PR when a new release appears; the
reconcile script will alert while the box lags; a human applies it with
`install.sh --upgrade-ollama`.

This is the same line [DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md) §4 draws
for the NUC — **pull, never push** — held one notch tighter for anything that
rewrites an executable.

## What's in `host/mac-mini/`

| File | Role |
| --- | --- |
| `versions.env` | the Ollama version pin. Committed (not gitignored) so **Renovate can read it** — `renovate.json` has a custom manager pointing the `github-releases` datasource at `ollama/ollama`. |
| `models.txt` | the declared model set, one tag per line, `#` comments. |
| `com.ollama.host.sh` / `.plist` | the five `OLLAMA_*` env vars + the Login-Item race self-heal, verbatim from Phase 4c. |
| `ollama-reconcile.sh` | compares declared vs actual; pulls missing models; reports version skew and undeclared models; pushes to Uptime Kuma. |
| `com.coralstack.ollama-reconcile.plist` | launchd timer — runs the reconcile daily. |
| `install.sh` | installs all of the above onto the mini. Idempotent. |
| `ollama.env.example` | the runtime config (`HEALTHCHECK_URL`, paths) — copied to a gitignored local file at install. |

### Renovate wiring

Image tags live in compose files, which Renovate understands natively. A version
pin in a shell-style `.env` does not, so `renovate.json` gains a
`customManagers` entry with a regex over `host/mac-mini/versions.env`. The
`# renovate:` comment above the pin is load-bearing — it carries the datasource
and package name. Don't reformat that file without checking the regex still
matches.

The practical effect: **the June→September gap would have opened a PR in June.**
An "ollama 0.30.10 → 0.31.x" PR in the same review queue as every image bump
would have made 2026-09-03 a non-event.

## Monitoring

The reconcile script follows the same alerting contract as
`services/smart/smart-check.sh` and `services/drift/drift-check.sh`
([MONITORING.md](MONITORING.md)): it pushes `up`/`down` plus a one-line reason to
an Uptime Kuma push monitor, and exits non-zero on any finding so a manual run
reports through its exit status too. If the script stops running entirely, the
heartbeat lapses and Kuma alerts on that instead — both failure modes covered.

> **The known blind spot stays known.** Kuma runs on the NUC, so the NUC cannot
> alert on its own death — MONITORING.md says so, and notes the mini doesn't
> count as an external watcher because nothing on it was watching. This work
> does **not** change that: the mini is now *watched*, not a *watcher*. An
> external dead-NUC check is still an open gap.

## Build plan

1. ✅ **Declare the mini** — `host/mac-mini/` with versions, models, LaunchAgent,
   and the Renovate custom manager. *(this change)*
2. ✅ **Reconcile script + launchd timer** — written. *(this change)*
3. ⬜ **Install on the mini** — run `host/mac-mini/install.sh`. Nothing on the box
   has changed yet.
4. ⬜ **Upgrade Ollama 0.30.10 → 0.33.3** and pull `qwen3.8:27b-nvfp4`. The
   deliberate human act described above; unblocks the original request.
5. ⬜ **Teach `services/drift/` about the mini** — today drift-check answers "is
   the apps VM running what the repo says." The same question now has a second
   host and no answer for it.
6. ⬜ **The NUC deploy primitive** — DEPLOY_ARCHITECTURE.md §1, still unbuilt and
   still the bigger prize. The mini's loop is the cheap rehearsal for it.

## Relationship to other docs

- [DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md) — the deploy model this host
  was missing from. Its build plan assumes one box; this is the second.
- [APP_UPDATES.md](APP_UPDATES.md) — the detection half. Renovate now covers the
  mini's runtime too, not just container images.
- [PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) Phase 4c — where the mini's setup
  was documented as prose. Still the narrative walkthrough; `host/mac-mini/` is
  now the executable copy.
- [HARDWARE_FAILURE.md](HARDWARE_FAILURE.md) — the blast-radius grading this
  doc's risk inversion rests on.
- [MONITORING.md](MONITORING.md) — the push-monitor contract the reconcile
  script follows.
- [AGENT.md](AGENT.md) — the reconcile script is the agent's intended first
  job; the agent is a fourth trigger, not new machinery.
