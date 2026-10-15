# The Mac mini — the host outside the deploy model

> **Status (2026-10-14):** ⚠️ installed and reconciling, and the pin does not
> hold. `host/mac-mini/` holds the mini's desired state as code, the reconcile
> script and its launchd timer have been installed since 2026-09-03, and the
> monitor has been **red since 2026-09-17**: the box runs Ollama 0.34.1 against
> a pin of 0.33.3, with a further 197 MB update staged and unapplied. Nobody
> was told, for 28 days, for two unrelated reasons — see
> [Why neither detection layer reached a human](#why-neither-detection-layer-reached-a-human).
>
> *(Superseded: the 2026-09-03 status here said "nothing installed on the box
> yet ... Ollama there is still 0.30.10". Both were true that day and neither
> is now.)*

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
`~/Library/Caches/ollama/updates/` that same day and stalled there, and nothing
was watching it fail.

> **This doc used to say the vendor's update mechanism "cannot succeed" on this
> box. That was too strong, and the truth is worse.** It can, and once did,
> unattended. Measured 2026-10-14: the app is **0.34.1** while `versions.env`
> pins 0.33.3, and the last human upgrade on this box was to 0.33.3 on
> 2026-09-03. Kuma's heartbeat history dates the change precisely — the
> reconcile reported "in sync" at 13:35 on 2026-09-16 and reported 0.34.1
> against the pin at 13:35 on 2026-09-17. Nobody ran anything in between.
>
> An updater that reliably fails is at least predictable; you pin the version
> and the pin holds. This one **drifts in both directions** — it can sit on a
> staged download forever *and* apply one without being asked — so the pin
> binds in neither. That is why `ollama-reconcile.sh` now reports a staged
> update as a finding of its own, separate from version skew: they are the two
> directions, and they have different remedies.

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
perform unattended. The reconcile script alerts while the box disagrees with its
pin; a human applies the change with `install.sh --upgrade-ollama`.

Renovate is meant to open a PR naming the new release, and that is still worth
having — but it is the remediation trigger, not the alarm, and it has not
actually fired once on this dependency. See
[Why neither detection layer reached a human](#why-neither-detection-layer-reached-a-human).

What a timer must *never* do and what it merely *does not* do have also turned
out to be different questions here. Nothing in this repo applies an Ollama
upgrade unattended. The vendor's own updater does, which is the subject of the
staged-update check.

This is the same line [DEPLOY_ARCHITECTURE.md](DEPLOY_ARCHITECTURE.md) §4 draws
for the NUC — **pull, never push** — held one notch tighter for anything that
rewrites an executable.

## What's in `host/mac-mini/`

| File | Role |
| --- | --- |
| `versions.env` | the Ollama version pin. Committed (not gitignored) so **Renovate can read it** — `renovate.json` has a custom manager pointing the `github-releases` datasource at `ollama/ollama`. |
| `models.txt` | the declared model set, one tag per line, `#` comments. |
| `com.ollama.host.sh` / `.plist` | the five `OLLAMA_*` env vars + the Login-Item race self-heal, verbatim from Phase 4c. |
| `ollama-reconcile.sh` | compares declared vs actual; pulls missing models; reports version skew, a **staged-but-unapplied update**, and undeclared models; pushes to Uptime Kuma. |
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

> **The practical effect was supposed to be: "the June→September gap would have
> opened a PR in June." It did not. Renovate has never opened an Ollama PR, for
> any version.** Measured 2026-10-14.
>
> The custom manager was never the problem — it matches, and the regex above
> still extracts `ollama/ollama` at `0.33.3` from the file as written. Renovate
> had the update: the Dependency Dashboard (issue #27) listed
> *"update dependency ollama/ollama to v0.40.3"* under **Rate-Limited**, with a
> checkbox to force it.
>
> **The mechanism was `prConcurrentLimit: 5` plus a queue nobody had emptied.**
> Five open Renovate PRs — #26, #30, #32, #70, #72, three of them sitting since
> July — held every slot in the repository-wide cap. Renovate creates nothing
> past that cap, so the one dependency whose PR was its *only* notification
> path spent four months queued behind an `alpine/socat` patch bump.
>
> Three things about that are worth keeping, because none of them look like a
> failure from the outside:
>
> - **The cap is per-repository and cannot be carved up.** Renovate's docs are
>   explicit that it is "enforced on a per-repository basis", and the only
>   documented nested budget is `vulnerabilityAlerts`, which gets its own
>   allowance on top. `packageRules` accepts a `prConcurrentLimit` key, but
>   there is no way to reserve a slot for the `mac-mini` label.
> - **`prPriority` does not help here, and this repo already had proof.** It
>   only *sorts* updates awaiting creation; it cannot evict a PR that exists.
>   The `stateful-review-carefully` rule has carried `prPriority: 5` the whole
>   time and it bought those packages nothing while the cap was full.
> - **An unreviewed PR is not free.** It looks like a tidy backlog and behaves
>   like a blocked channel. Four of the five holding slots were trivial.
>
> What changed, and what did not: `renovate.json` now sets
> `prConcurrentLimit: 10` (Renovate's own default) and gives the mac-mini rule
> `prPriority: 10` so it takes the next slot that frees. **Both are
> mitigations.** The cap saturates again at ten unreviewed PRs, and `minimumReleaseAge: "3 days"`
> correctly holds the newest patch back a little longer besides — 0.40.4 landed
> 2026-10-12 and was not yet eligible on the 14th, which is the setting working,
> not failing.

## Why neither detection layer reached a human

This host had two independent layers pointed at exactly this failure, and in
September both were live, both looked healthy, and neither delivered. They
failed for unrelated reasons, which is the only interesting thing about it —
there was no single thing to fix.

| Layer | Supposed to | What actually happened |
| --- | --- | --- |
| **Renovate PR** | Open "ollama 0.33.3 → 0.34.x" into the review queue | Never opened one. The repo-wide PR cap was full of stale trivial bumps; the update sat on the Dependency Dashboard, which notifies nobody. |
| **Reconcile monitor (#12)** | Push `down` daily with the reason | Did exactly that, every morning from 2026-09-17. Kuma notifies on state *changes* and the monitor's `resend_interval` was `0`, so it alerted **once** and then never again. |

Between them, the pin went unenforced for 28 days while every component
reported success. The reconcile ran. The push arrived. The monitor went red.
The ntfy channel was attached and fired correctly — verified, all 12 monitors
have exactly one notification each. One alert went out on 2026-09-17 and the
system then had nothing further to say about a condition that could not fix
itself.

**The ordering lesson is the useful one.** The PR was documented here as the
primary detector and the monitor as the backstop. That is backwards. A PR is
rate-limited, competes for slots with routine work, and depends on someone
reading a queue; the monitor pushes to a phone and is subject to neither. The
monitor is the alarm. **The PR is the remediation trigger** — the thing that
tells you *which version* to move to once you already know you have to move.
Treating it as the alarm is what left this box with a notification path that a
backlog of `alpine` bumps could switch off.

The repair is in two places, and neither is Renovate:

- `services/autokuma/monitors/*.toml.template` now set `resend_interval`
  per monitor, so a standing finding keeps being mentioned. The mini's is `7`
  — weekly, against a daily check.
- `host/mac-mini/ollama-reconcile.sh` now reports a **staged-but-unapplied
  update** as its own finding, so "about to move" is visible and not just
  "has moved".


## Monitoring

The reconcile script follows the same alerting contract as
`services/smart/smart-check.sh` and `services/drift/drift-check.sh`
([MONITORING.md](MONITORING.md)): it pushes `up`/`down` plus a one-line reason to
an Uptime Kuma push monitor, and exits non-zero on any finding so a manual run
reports through its exit status too. If the script stops running entirely, the
heartbeat lapses and Kuma alerts on that instead.

Both failure modes are *detected*. Whether either is **reported more than once**
is a separate property, and it is the monitor's `resend_interval`, not the
script's — which is the distinction this host paid 28 days to learn. The
script's job is to produce a true finding every morning; it did. Saying it out
loud more than once is Kuma's job, and it was configured not to.

**The monitor is declared, not clicked.** It lives at
[services/autokuma/monitors/ollama-mac-mini.toml.template](../services/autokuma/monitors/ollama-mac-mini.toml.template)
with its push token pinned by `setup.sh`, exactly like the SMART and drift
monitors. What is *not* automated is the last hop: the mini is not on the apps
VM's docker network, so `setup.sh` cannot write the URL into a file over here.
It prints the public form as **step 6** of its run —
`https://status.<BASE_DOMAIN>/api/push/<OLLAMA_MINI_PUSH_TOKEN>` — and that
goes into `~/.coralstack/ollama.env` by hand. Same shape as the Proxmox host's
SMART runner, for the same reason.

> **A blank `HEALTHCHECK_URL` is the quiet failure mode here**, and it was the
> state this box shipped in. The reconcile still runs at 06:35, still finds a
> lagging Ollama or a missing model, still exits non-zero — into a log nobody
> reads. Everything above only works once that line is filled in.
>
> **Wired and proven 2026-09-04:** the URL is set, a manual run pushed
> `status=up`, and Kuma monitor #12 recorded
> `mac-mini: ollama in sync with the repo`. Note `python3` is unusable on this
> box — it triggers the Xcode CLT installer — so edit that file with `sed`, not
> a Python one-liner.
>
> **And then it went red on 2026-09-17, and stayed red.** The wiring was proven;
> what was not proven was that it would speak more than once. The monitor has
> reported a version skew every morning since, and the owner heard about it
> exactly once — 28 days before anyone looked. `resend_interval = 0` is the
> whole explanation, and it is now `7` in the monitor's `.toml`
> ([MONITORING.md](MONITORING.md), *The alert that only speaks once*).
>
> Worth separating the two claims, because "wired and proven" invited the
> wrong conclusion: **the heartbeat path was proven, the alerting cadence was
> assumed.** A one-shot alert on a dead-man's-switch watching a condition that
> cannot self-heal is indistinguishable from no alert, a day later.

> **The known blind spot stays known.** Kuma runs on the NUC, so the NUC cannot
> alert on its own death — MONITORING.md says so, and notes the mini doesn't
> count as an external watcher because nothing on it was watching. This work
> does **not** change that: the mini is now *watched*, not a *watcher*. An
> external dead-NUC check is still an open gap.

## Build plan

1. ✅ **Declare the mini** — `host/mac-mini/` with versions, models, LaunchAgent,
   and the Renovate custom manager. *(this change)*
2. ✅ **Reconcile script + launchd timer** — written. *(this change)*
3. ✅ **Install on the mini** — done 2026-09-03. Agents bootstrapped, reconcile
   timer scheduled 06:35.
4. ✅ **Upgrade Ollama 0.30.10 → 0.33.3** and pull `qwen3.8:27b-nvfp4` — done
   2026-09-03; the original request is closed. Confirmed 2026-09-04 by a
   reconcile run reporting `ollama in sync with the repo`.
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
