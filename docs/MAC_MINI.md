# The Mac mini — the host outside the deploy model

> **Status (2026-10-17):** ✅ oMLX 0.7.1rc1 **installed and serving**; Ollama
> stopped, still installed, login item disabled, and one line in
> `versions.env` away from being the primary again. The acceptance criteria in
> [Done means](#done-means) are measured and met: a 230k-token conversation
> survives an agent switch in **14 s** against 62 minutes to rebuild it, and a
> restart in 15 s. Decode is within 5% of Ollama on realistic prose.
>
> **Not done:** Open WebUI still points at the stopped Ollama, so household
> chat is down until this branch merges and deploys — that compose change
> travels by `git pull`, not from here. Perennial's relay also needs its path
> moved to `/openai/v1/chat/completions` in its own repo.
>
> *(Superseded twice. The 2026-09-03 status said "nothing installed on the box
> yet ... Ollama there is still 0.30.10". The 2026-10-14 status said the pin
> did not hold, with a 197 MB update staged. Both were true on their day.)*

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
| `omlx-models.txt` | the declared oMLX model set, as `repo@revision`. A separate file from `models.txt` because Ollama tags and Hugging Face revisions are different identifier spaces that reconcile differently. |
| `omlx-serve.sh` | the `omlx-cli serve --headless` flags, with a justification each. The oMLX counterpart of `com.ollama.host.sh`, and much smaller because it needs none of its workarounds. |
| `com.coralstack.omlx.plist` | launchd agent for the server itself — `RunAtLoad` + `KeepAlive`, the shape Ollama's GUI app could never have. |
| `omlx.env.example` | oMLX's runtime config (`OMLX_API_KEY`, model and cache paths) — copied to a gitignored local file at install, with the key generated there. |

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


## Serving the model through oMLX

The mini's problem stopped being "is it up to date" and became "does it
remember". One client runs two long-lived agents through Open WebUI, each
sending ~46k tokens and appending between calls. Ollama's MLX runner keeps
**one** prompt-prefix cache, so the two agents evict each other: in Ollama's own
log for 2026-10-07, a 46,279-token prompt took 442 s to prefill, and a
same-sized request 72 s later matched **2 tokens** and prefilled cold again.
About 7 minutes per switch.

[oMLX](https://github.com/jundot/omlx) keeps a paged cache per conversation and
spills it to SSD. A runtime-only spike on 2026-10-16 measured, one call at a
time with `max_tokens: 1`:

| Call | Time | Cached tokens |
| --- | ---: | ---: |
| A, cold | 419 s | 0 |
| A, one turn longer | 3.4 s | 46,164 of 46,334 |
| B, cold | 419 s | 0 |
| A after B | 2.9 s | 46,327 of 46,509 |
| A after a full oMLX restart | 3.0 s | 46,502 of 46,678 |

**Cold prefill is no faster** — 110 tok/s against Ollama's 105, consistent with
the ~120 tok/s measured on 2026-10-14 being the hardware ceiling rather than
version lag. So this is not a speed change. It buys **hit rate**: the 3-second
column survives an agent switch and a restart, where Ollama's did not. SSD cost
is ~6.4 GB per 46k conversation (2.9 GB of KV at 64 KB/token plus ~3.5 GB of
Gated DeltaNet state snapshots).

### The decode gate, and the model choice it forced

Every spike call used `max_tokens: 1`, so **oMLX's decode rate is unmeasured**,
and the household feels decode where the agents feel prefill. That gap turned
out to matter more than the spike implied, because of one line in Ollama's own
server log on the live box (2026-10-16):

```
msg="speculative decode stats" iterations=60 drafted=120 accepted=100 acceptance=0.83
```

That is Ollama getting **~1.8 accepted tokens per decode step** out of Qwen3.8's
multi-token-prediction head. oMLX has the verify loop too — 0.7.x spent most of
its release notes on it, "Exact Lightning MTP" and fused kernels for "MTP verify
windows" on Qwen3.8-27B specifically — but **the head has to be in the
checkpoint**, and the conversion the spike used had it stripped. The weight map
is the discriminator, not the repo name:

| Conversion | MTP weight keys | Size |
| --- | --- | --- |
| `mlx-community/Qwen3.8-27B-nvfp4` | **0** of 1,682 | 15.45 GB |
| `Jundot/Qwen3.8-27B-oQ4e-mtp` | **29** of 2,209 | ~15 GB |

So the declared model is the second one — published by the oMLX author in
oMLX's own oQ format, 4.887 effective bits/weight, imatrix-quantised with
KL-divergence tables against BF16 on its model card, at the same footprint. Had
this not been caught, the box would have been running a heavily MTP-optimised
engine on a model that cannot drive it, and the symptom would have been "the
new thing feels slower" with no obvious cause.

**It is still a gate**, and it now has a number. "The household chat still
works" is not a sufficient criterion — a 2× decode regression passes it while
being a real downgrade for the people who use this box most. Baseline taken
2026-10-16 on an idle mini, Ollama 0.40.4, server-side timings, 512 generated
tokens per run:

| workload | prefill tok/s | decode tok/s | MTP acceptance |
| --- | ---: | ---: | ---: |
| count, ~820 tok | 124-130 | 36.8 | 0.99 |
| prose, ~845 tok | 124-130 | 27.3-27.8 | 0.61-0.63 |
| prose, ~11.8k tok | 122 | 24.8-26.0 | 0.61-0.66 |

**Two workloads, because one of them lies.** A first pass used only the
counting prompt and reported 36.6 tok/s — with MTP acceptance of 0.99, because
counting is pathologically predictable. Free prose gets 0.61-0.63, and
Perennial's agent traffic sits between at 0.83. So MTP is worth between 1.6×
and 2.0× depending on what is being generated, and any decode figure quoted
without its workload is meaningless. The gap between the two rows **is** the
MTP contribution, which also makes it the test of whether MTP is engaging at
all: if oMLX shows no gap, the head is not being used.

This also vindicates the 2026-10-14 figure of 24-30 tok/s, which the prose rows
reproduce. The earlier criticism of it in this doc was about sample size — one
128-token run per point — not about the number, which held up.

**The derived figure is the one that justifies the model choice.** At
acceptance 0.63 with `avg_draft=2.00`, Ollama banks ~1.63 accepted tokens per
step, so a head-stripped conversion would decode prose at roughly **17 tok/s** —
a ~38% regression on exactly the workload the household feels. That is what
`mlx-community/Qwen3.8-27B-nvfp4` would have delivered.

So the gate is: **oMLX on the prose workload at ≥24.8 tok/s**, with the
count-vs-prose gap present. The fallbacks if it misses are in
`omlx-models.txt`: an older revision of the same checkpoint, and an oQ6e-mtp at
22 GB if 4.887 bits costs quality.

### Result: the decode gate passes, and the first answer was wrong

Measured 2026-10-16 on oMLX 0.7.1rc1 with `Qwen3.8-27B-oQ4e-mtp`, same box and
same harness:

| workload | Ollama | oMLX | delta |
| --- | ---: | ---: | ---: |
| count, ~850 tok | 36.8 | 31.2 | −15% |
| prose, ~890 tok | 27.5 | **26.1** | **−5%** |
| prose, ~12k tok | 25.4 | 24.2 | −5% |

**COMPARE GENERATION-ONLY ON BOTH SIDES.** The first pass at this reported
−34% and "gate failed", and it was wrong: Ollama's figure comes from
`eval_duration`, which is the generation phase, while oMLX's log line —
`512 tokens in 24.91s (20.6 tok/s)` — is the **whole request including
prefill**. On a 12k prompt that lands at "4.5 tok/s", which is obviously not a
decode rate and is what gave the error away. oMLX's generation-only time comes
from its MTP telemetry (`backbone + mtp + sample`) or from
`usage.generation_tokens_per_second`; the arithmetic checks out, since
24.91s total − 16.8s generation leaves ~8.1s to prefill 847 tokens, i.e.
~105 tok/s, which matches the spike's measured prefill.

So on the workload the household actually feels, the two runtimes are within
5% of each other. The MTP head in the checkpoint is doing its job
(`mtp_enabled: True`, 2.2-3.5 tokens per cycle), and oMLX spends its deeper
drafting on a slower cycle to arrive at roughly the same place. Prefill is the
real regression at ~105 tok/s against Ollama's ~125, and that is the number the
paged cache is supposed to make irrelevant.

> Note one number that gets *worse* and does not matter: oMLX's cold prefill was
> 110 tok/s in the spike against Ollama's 122-130 here, so a cache miss is
> ~12% slower to recover from. The entire point is that misses stop happening,
> but it is the right thing to look at first if the cache ever behaves worse
> than the spike.

### One runtime serves at a time, and the switch is one line

48 GB does not hold both. Ollama's copy is 18.2 GB of weights reaching a 33 GB
steady state with two 32K slots; oMLX's is 15.45 GB plus a ~9.6 GB hot cache,
about 25 GB. Both loaded wants ~58 GB against a ~44 GiB wired ceiling.

So `versions.env` carries `MINI_PRIMARY_RUNTIME`, and it is the cutover and the
rollback both:

```bash
bash host/mac-mini/install.sh --install-omlx        # fetch + verify the bundle
bash host/mac-mini/install.sh --fetch-omlx-models   # ~15 GB, pinned revision
bash host/mac-mini/install.sh --cutover             # stop Ollama, start oMLX
```

`--cutover` is **the only thing in this repo that stops Ollama**, and nothing
reaches it by accident: a plain `install.sh` run with oMLX declared primary
installs the agent but refuses to start it while Ollama still holds a model
resident, and prints the verb instead. Rollback is `MINI_PRIMARY_RUNTIME=ollama`
plus a re-run, then `ENABLE_OLLAMA_API: "true"` and a redeploy on the apps VM.
Ollama and its four models stay installed throughout — the other three
(`qwen3.6:27b-nvfp4`, the coding MoE, `gemma4:26b-mlx`) remain declared in
`models.txt` and reachable only by rolling back, because using one means
stopping oMLX first.

### Installed from the DMG, which reverses this file's own Homebrew decision

Above, this doc records Ollama being chosen "over Homebrew because it
auto-updates and ships the CLI" — and nearly every incident since traces to that
sentence. The instinct to prefer a no-updater install for oMLX is right, and the
tap defeats it for two measured reasons (2026-10-16): the formula's `url` moves
with upstream and the tap carries no versioned formulae, so `brew install` would
install whatever the tap currently points at and `versions.env` would be
decorative — the pin has to bind, whichever release it names; and its custom
kernels need **full Xcode**, not the CLT — its own guard says "`metal` ships
with Xcode, not the Command Line Tools" — where `qwen35_prefill` is the prefill
path for this model's architecture and `decode_fast` the decode path. A brew
build without Xcode silently omits both, so it would be a slower binary than
the one the spike measured.

The DMG ships those kernels precompiled and bundles its own CPython 3.11 and
MLX, needing no toolchain. **The updater objection is answered structurally, not
by a promise:** launchd runs `omlx-cli`, a different executable in the same
bundle with zero update-check symbols in it against 6 in the GUI binary, and
`install.sh` puts the bundle in `~/.coralstack/` rather than `/Applications` so
the GUI binary cannot be reached by a double-click or a Login Item. The
reconcile reports a copy appearing in `/Applications` as a finding.

> **Install the Command Line Tools on this box anyway**, independently of the
> above. They are absent today (`xcode-select -p` errors), which is why `git`
> and `python3` both trigger the installer, why `install.sh`'s own "run this
> from a checkout of this repo" cannot be followed there, and why deploying to
> it needs the `git archive` + `scp` staging pattern. Installing them retires
> all three workarounds and costs nothing this design depends on.

### An "rc" tag is this project's release train

`versions.env` pins **0.7.1rc1**, and that is upstream's current release rather
than a prerelease taken on. GitHub's `releases/latest` returns `v0.7.1rc1` with
`prerelease=false` and `draft=false`, and the project's homepage download button
points at `releases/latest`.

An earlier draft of this change got that backwards, and the failure would have
been invisible. It read `prerelease=false` on an "rc" tag as upstream
mislabelling its prereleases, and used `versioning: semver` in `renovate.json`
to filter them — `0.7.1rc1` is not valid semver, so Renovate skips it. That
does not mean "hold until a stable release"; it means the dependency goes quiet
while the pin sits on an old version and every check reports green. **That is
the same shape as the four months this repo spent not hearing about Ollama,
reached from the opposite direction.** `renovate.json` now sets versioning per
package — `ollama/ollama` stays semver, `jundot/omlx` gets pep440, which
understands rc tags — with `ignoreUnstable` off and `allowedVersions` excluding
only `.dev` snapshots.

Pinning an rc on the household's chat server is a real choice, and it is the
one this host is already graded for: the mini is where a bad update costs
nothing, which is the same risk inversion that makes model pulls automatic here
and nowhere else.

### Read the installed binary's help, not the docs for `main`

Two findings from the installed binary that the flag check in `install.sh`
caught before anything was installed, and they are the argument for that check
existing:

- **`--headless` does not exist in 0.7.0.** The README on the default branch
  documents it, and the first draft of `omlx-serve.sh` passed it. `serve
  --help` on the 0.7.0 binary lists every other flag in that file and not that
  one. Under a `KeepAlive` agent this would have been a 30-second crash loop
  whose only symptom was a log file nobody reads.
- **`OMLX_API_KEY` *is* read from the environment**, verified by binding
  `0.0.0.0` with no `--api-key` flag — which the server refuses without a key.
  So the key stays out of `ps`.

> **A consequence to check once it is serving.** 0.7.0 had no way to switch the
> web UI off, so the admin dashboard at `/admin` and the chat UI at
> `/admin/chat` share the API's port, and with `--host 0.0.0.0` they are
> reachable from the household LAN. Whether a browser can reach `/admin`
> without the key is unverified. If it is open, the options are a loopback bind
> behind a proxy, or `--headless` if 0.7.1rc1 has it.

### The cutover took seven attempts, and every failure reported success

Worth recording in full, because the shape is this host's recurring theme: not
one of these announced itself. The install printed a success message each time,
and the box was in a different state than the message claimed.

| What failed | How it looked | What it was |
| --- | --- | --- |
| `--hot-cache-max-size 20%` | "oMLX agent bootstrapped", nothing serving | The percentage form is in the README; 0.7.1rc1 rejects it. Its own help gives the default as `0 (disabled)`, so omitting the flag would have silently shipped the in-memory tier switched **off** |
| `--cutover` not verifying | Success printed over a `KeepAlive` crash loop | launchd accepting a job is not the same as a server answering. It now polls `/v1/models` for 180s and fails **back** to Ollama rather than leaving nothing up |
| `bootstrap` after `bootout` | Agent silently absent from `launchctl list` | "Bootstrap failed: 5: Input/output error" while the old job was still unloading, and the exit status was discarded |
| The env agent's self-heal | Ollama back seconds after being stopped | `ps eww` on a *dying* PID returns nothing, so "missing its env vars" and "no longer exists" were indistinguishable — and the remedy is `open -a Ollama` |
| `launchctl bootout` of the login item | Ollama back 2-40s later, PPID 1 | Booting out a service launchd keeps alive gets it relaunched once, and the `disable` override does not prevent it. `disable` alone, with no bootout, is both sufficient and durable across reboots |
| **The reconcile itself** | Ollama back, *after* the cutover's own post-stop check passed | **`ollama list` against a stopped server does not fail — the CLI launches the Mac app to satisfy it.** The reconcile is install.sh's last step, so every cutover stopped Ollama and then started it again |

**That last one is the instructive one.** For six runs the evidence pointed
squarely at launchd: the revived process had PPID 1, arrived via
`runningboardd`, and `launchctl print-disabled` confirmed the login item was
disabled — so three fixes went into the launchd machinery, each plausible, each
removing a real bug, none of them the cause. What settled it was stopping
Ollama **by hand** with nothing else running and watching it stay down for 60
seconds. The difference between that and the script was not launchd at all.

A monitoring script that starts an 18 GB runtime as a side effect of checking
on it is worse than no check, on a box where two runtimes do not fit. Liveness
is now probed with `curl` against `/api/tags`, the version is read from
`Ollama.app`'s `Info.plist` when the server is down, and every remaining CLI
call requires the server to already be up.

> **The transferable rule:** on this host, verify the box is in the state the
> script says it is in. Every incident in this document — the June version lag,
> the 28-day silence, the merged-but-not-deployed pattern, and all seven of
> these — is a gap between a success message and reality.

### Binding, the key, and the cache

`--host 0.0.0.0`, the same exposure Ollama already has on 11434 — except oMLX
**refuses a non-loopback bind without an API key**, so this is strictly better
than the status quo rather than a new hole. The key is generated on the box by
`install.sh`, kept in the untracked `~/.coralstack/omlx.env`, and exported
rather than passed as a flag, because a command line is readable by every local
user through `ps` while a process environment is not.

The SSD cache is capped at **40 GB** explicitly. The upstream default is `auto`,
meaning 50% of free disk — about 400 GB on this box. The reconcile reports both
the cache exceeding its cap and free space falling below it.

### Models are pinned to a revision, and the pin is ours to verify

`omlx-models.txt` holds `repo@revision`, never a branch: `main` on a model repo
is rewritten in place, so a quantisation's numerics can change with no version
to bump and no release notes. Renovate does **not** watch this file — no Hugging
Face datasource was confirmed to exist — which is fine, because a pinned
revision cannot drift.

But oMLX's `--model-dir` layout records no revision, so a directory on disk
cannot say which conversion it holds. `--fetch-omlx-models` therefore writes a
`.coralstack-revision` sidecar last, after every file lands, and the reconcile
compares it to the pin. A model present without a sidecar is a finding, not a
pass: it came from somewhere else and its numerics are unknown.

**This is a deliberate divergence from the risk inversion above**, which says
model pulls are auto-applied on this host. That still holds for `ollama pull` —
one resumable, self-verifying command. A pinned Hugging Face revision is a
multi-file ranged download whose integrity and provenance we establish
ourselves, the downloader lives in `install.sh`, and 15 GB deserves a human in
the room. So the timer reports; a person fetches.

### How Open WebUI and the client reach it

Open WebUI stays the front door. It gains an OpenAI-compatible connection to
`http://<MAC_MINI_IP>:8000/v1` with the oMLX key, and `ENABLE_OLLAMA_API` goes
to `"false"` so the household's model picker does not offer five models where
choosing the wrong one squeezes the box.

For the client, the route changes from `/ollama/v1/chat/completions` to
**`/openai/v1/chat/completions`**, same Open WebUI API key, same public URL
behind the same auth. Going direct to the mini was considered and rejected: it
would have traded away a working authenticated endpoint reachable from
anywhere.

> **One thing to measure, because it decides whether this holds.** Open WebUI is
> a proxy, and a proxy that alters the prompt prefix destroys exactly what this
> change buys. oMLX reports `cached_tokens` on every response, so the test is
> two identical calls through `/openai/v1/chat/completions`: if the second
> reports ~46k cached, the passthrough is prefix-stable and the front door
> stays. If it reports ~0, the fix is a Caddy vhost straight to the mini's
> `:8000`, which is additive and needs no change on the mini.
>
> Note the Ollama log cannot settle this on its own: a 2-token match on a
> *different* conversation is expected whether the cause is eviction or a
> mutating proxy. Only a return to the same conversation tells them apart, and
> the spike measured that against oMLX directly, not through Open WebUI.

Open WebUI also fires its own inference for chat titles and tags — each one a
cold prefill on a 27B competing with a member's reply and an agent's 46k
prefill. Both are disabled in the compose file, and both want confirming in
Admin Settings → Interface, because Open WebUI ignores an unrecognised
environment variable without an error.

### What the reconcile now checks

The same script, the same single push, the same monitor — the question "is the
mini running what the repo says" just has two runtimes now. Added: oMLX's
version against its pin, read from the bundle so a stopped server still answers
it; a stray `/Applications/oMLX.app`; the agent loaded and `/v1/models`
answering; `auth.allow_unauthenticated_inference` in `settings.json`, the one
setting that would turn the keyed LAN bind into an open one; declared models
present at the pinned revision; and the SSD cache against its cap.

Two existing behaviours had to change, and both were latent bugs that only a
second runtime exposed:

- **`PRESENT` and `LIVE` are now separate for Ollama.** They were one flag, so a
  stopped Ollama skipped the version check too — and the version pin is a
  property of the installed binary, not of a running server. Demoting Ollama to
  the rollback runtime would have silently stopped checking the thing this
  host's entire history is about.
- **`ollama --version` is parsed by matching the version line**, not by taking
  the last field of line one. With the server stopped — now its normal state —
  it prints a "could not connect" warning first, and the old parse read that
  warning's last word as the version and reported a skew against every pin.

A stopped non-primary runtime is a **note**, never a finding, because a finding
that can never be cleared is the 2026-09-17 alerting bug wearing a different
hat. What *is* a finding is the other runtime still holding weights resident —
`ollama ps` non-empty while oMLX is primary — because that is the half-finished
cutover, and the memory-thrash case.

### Measured: the cache is the whole case, and it holds

All on the installed service, 2026-10-16/17, `Qwen3.8-27B-oQ4e-mtp` on oMLX
0.7.1rc1. `host/mac-mini/alternation-test.sh` is the harness; prompt sizes are
calibrated against `/tokenize`, not estimated.

**At 46k tokens** — the size the agents run today:

| step | prompt tokens | cached | wall |
| --- | ---: | ---: | ---: |
| A cold | 46,174 | 0 | 418 s |
| A + one turn | 46,198 | 45,056 | 14 s |
| B cold | 46,255 | 0 | 417 s |
| **A after B** | 46,198 | 46,193 | **1 s** |
| **A after a restart** | 46,198 | 46,193 | **6 s** |

**At 230k tokens** — near the model's 262,144 limit:

| step | prompt tokens | cached | wall |
| --- | ---: | ---: | ---: |
| A cold | 230,853 | 0 | 3,700 s (62 min) |
| A + one turn | 230,877 | 229,376 | 52 s |
| B cold | 230,813 | 0 | 3,731 s (62 min) |
| **A after B** | 230,877 | 230,872 | **14 s** |
| **A after a restart** | 230,877 | 230,872 | **15 s** |

**The agent switch that costs Ollama 442 s costs oMLX 1 s at 46k and 14 s at
230k.** The restart rows prove the SSD tier genuinely persists, since a restart
clears RAM. 418 s cold at 46k reproduces the spike's 419 s, which is the
evidence the harness is sound.

Three things in those tables are worth understanding rather than just reading:

- **Cold prefill degrades with context**: 105 tok/s at 46k, 62 tok/s at 230k.
  62 minutes to build a 230k conversation is not usable interactively by
  either runtime — it is the same hardware ceiling — so a 230k workload is
  only viable *because* the cache makes it a one-time cost.
- **The first append after a cold prefill is the expensive one.** It is served
  block-aligned (45,056 = 22 × 2048; 229,376 = 112 × 2048) and the partial
  tail is recomputed. By the next visit the full prefix has been stored
  (46,193 and 230,872), so steady-state per-turn cost is the 1-14 s row, not
  the 14-52 s one.
- **The whole thing rests on the prefix being append-only.** An edit near the
  start of the prompt — a changed system prompt, an agent rewriting its own
  core memory — invalidates from that point and costs the full cold prefill
  again. At 230k that is an hour.

**And Ollama cannot do this at all at that size.** Its live configuration runs
a 32,768-token context, so at the context length this host is now configured
for, oMLX is not 5% slower at decode in exchange for a faster cache — it is
the difference between possible and impossible.

### The GDN codec: half the disk for nothing

Same harness, same prompt sizes, two 46k conversations, fp32 against rht_int8
on a forced `ssd_sidecar` layout:

| | fp32 (upstream default) | rht_int8 |
| --- | ---: | ---: |
| SSD footprint | 15 GB | **7.5 GB** |
| switch (A after B) | 1 s | 1 s |
| after a restart | 6 s | **4 s** |
| cold prefill | 418 s | 422 s |

Half the disk, no speed cost, and a faster restart because there is less to
read back. Adopted as the default in `omlx-serve.sh`. At 230k that is ~15 GB
per conversation instead of ~30, so the 300 GB cache holds ~20 rather than ~10.

The trap is recorded in the wrapper: the codec applies **only** on the sidecar
path, and the `embedded` layout stores raw fp32 regardless (jundot/omlx#2700,
open), so `rht_int8` with `gdn_snapshot_storage = auto` may do nothing at all.

### Concurrency: measured, and better than the issue tracker suggested

The sub-agent case — a parent agent spawning a child, both generating at once.
Measured 2026-10-17 with distinct prompts so nothing shares a cached prefix,
256 tokens each, short prompts so this isolates decode rather than prefill:

| parallel | aggregate tok/s | per-request tok/s | speedup |
| ---: | ---: | ---: | ---: |
| 1 | 20.9 | 20.9 | 1.00× |
| 2 | 32.5 | 16.2 | **1.55×** |
| 4 | 44.4 | 11.1 | **2.12×** |

Two agents generating 256 tokens each take **15.7 s in parallel against 24.4 s
serialised**. Per-request speed drops, aggregate throughput rises — the normal
continuous-batching trade, and the right one when a parent and child are both
working.

**This corrects an earlier claim in this document.** jundot/omlx#4402 reports
VLM-engine scaling of ~1.2× across 8 requests on an M3 Ultra, and that was
repeated here as evidence that the brief's concurrency justification was dead.
It is not dead on this box: 2.12× at four parallel sits inside the 1.51-3.39×
that `vllm-mlx` reports for five concurrent requests, and oMLX inherits that
continuous-batching machinery. Someone else's hardware is not a measurement of
yours.

### Context length against concurrency — they share one budget

With `--memory-guard-gb 42` the process memory enforcer reports a 42.0 GB
ceiling. Weights take 16.6 GB, leaving **~25 GB for context** at the measured
61 KB per token:

| context per conversation | memory each | concurrent that fit |
| ---: | ---: | ---: |
| 262k | 16.0 GB | **1** |
| 128k | 7.8 GB | **3** |
| 96k | 5.9 GB | 4 |
| 64k | 3.9 GB | 6 |
| 46k | 2.8 GB | 9 |

**128k is the chosen target**, for two independent reasons. A cache
invalidation costs a full cold prefill — ~25 min at 128k against ~70 min at
262k — and 262k leaves room for exactly one conversation, so it forecloses the
sub-agent case entirely. At 128k a parent and child fit with room for the
household beside them.

> **There is no server-side context cap.** `omlx-cli serve` has no
> max-context flag; the server accepts whatever the client sends, up to the
> model's 262,144. So the 128k decision is enforced in the CLIENTS, not here.
> The memory guard will throttle or refuse a prompt it cannot fit rather than
> crashing, but nothing stops a 262k prompt from arriving and costing an hour.

### The hot cache is disabled, and that cost nothing

`--hot-cache-max-size 0`, which is also upstream's default. Verified by running
the full alternation test with it off and comparing against the same test with
1 GB:

| | hot cache 1GB | hot cache 0 |
| --- | ---: | ---: |
| switch (A after B) | 1 s | **1 s** |
| after a restart | 4 s | **4 s** |
| SSD footprint | 7.5 GB | 7.6 GB |

Identical. The SSD tier does all the work, so every gigabyte given to this
tier would be a gigabyte denied to the active context or a second concurrent
conversation, in exchange for nothing measurable.

### The guard can panic Metal, so the ceiling is explicit

`--memory-guard aggressive` alone let oMLX believe it had a 46.5 GB static
ceiling while this box's kernel wires only 44 GB. The server says what that
means itself:

> Metal cap (44.0GB, kernel iogpu.wired_limit_mb) is below the oMLX static
> ceiling; Metal will clamp allocations to the cap and panic if a request
> exceeds it.

So the failure mode for a large context was a panic rather than a graceful
refusal. `--memory-guard-gb 42` moves the enforcer to `tier=custom,
ceiling=42.0GB`, under the kernel cap. **Mitigated, not eliminated:** the
advisory static ceiling is computed separately and still exceeds 44 GB, so the
warning persists. Clearing it entirely needs
`sudo sysctl iogpu.wired_limit_mb=46694`, which needs root and does not
survive a reboot. The 230k run peaked near 31.6 GB, so there is real headroom.

### One large prompt can freeze the service, and config only half-fixes it

There is no server-side context cap: `omlx-cli serve` has no max-context flag,
so a client can send up to the model's 262,144 tokens and occupy the GPU for
over an hour. The question is what that does to everyone else.

Measured 2026-10-17 — a 24-token request sent 10 seconds into a cold 46k
prefill, timed end to end:

| `scheduler.chunked_prefill` | small request latency |
| --- | ---: |
| `false` (upstream default) | **409 s** |
| `true` | **58 s** |

With chunking off the small request waits for the **entire** prefill: the
service is frozen, not degraded. Chunking lets it interleave, a 7× improvement,
and it is now the declared default in `omlx-serve.sh`.

**But 58 s for a 24-token reply is still a bad experience, and it scales with
the offending prompt** — roughly 3 minutes at 128k instead of 25. So config
mitigates and does not solve. Worth being clear about the three separable
layers:

1. **Can one request monopolise the GPU?** `chunked_prefill = true`. Done, 7×.
2. **Can a client send an unbounded prompt?** Nothing here prevents it. Do not
   expose oMLX publicly — which also retires the "Caddy vhost straight to the
   mini" fallback suggested earlier in this document. If the surface ever does
   widen, a request-body size limit at the edge is a crude but effective proxy
   for a context cap (~128k tokens is roughly 500 KB of JSON).
3. **Should the exposed surface be an agent rather than a model?** A managed
   agent with a configured context window cannot send a 262k prompt; a raw
   OpenAI-compatible endpoint always can. Letta does own context ceilings and
   compacts before overflowing — but its compaction REWRITES history, so it
   buys the cap by spending the cache. See below.

Note this is self-inflicted before it is adversarial: a member pasting a long
document into the household chat causes it by accident, and the distinction
does not help the people who cannot chat. Also noted for whenever the surface
widens: `server.cors_origins` is `["*"]`, which the mandatory API key makes
non-exploitable on its own but is loose.

### The load-bearing assumption, and where it breaks

Everything above depends on the prefix being **append-only**, because the cache
keys on it. An edit near the START invalidates everything after it, and the
cost is a full cold prefill: ~7 min at 46k, ~25 min at 128k, ~70 min at 262k.

**Letta's core memory sits in the system prompt, so every memory rewrite does
exactly this.** That is not a property of oMLX and Ollama would not help — it
is prompt architecture, and it is the single biggest risk to the value measured
here. Two consequences worth designing around:

- **Batch memory writes**, or confine them to a window where an hour of
  re-prefill costs nothing. A sleep-time agent is the shape that fits.
- **Summarisation must append, not rewrite.** A pass that appends a summary and
  truncates only the tail keeps the prefix valid. One that rewrites history
  destroys the cache as thoroughly as a memory edit.

**And this is the same problem as the context cap above.** Letta's compaction
is what would enforce a ceiling, and compaction is what invalidates the prefix.
So both the DoS surface and the cache depend on one decision: *when is the
prefix allowed to change?* Batch memory writes and compaction into a scheduled
window, keep the ceiling low enough that a forced rebuild fits inside it, and
outside that window the prefix stays append-only and the 1-second switches
hold. One window answers both.

### Why oMLX is slower at decode, and why that is not oMLX's fault

oMLX beats Ollama on text-only models. Qwen3.8-27B is a vision-language
checkpoint, so oMLX routes it to its **VLM engine**, which carries an open
performance defect: jundot/omlx#3882 reports its `BatchGenerator` path well
below plain mlx-lm `generate_step` (Qwen text 13.8 vs 82.7 tok/s), and the
maintainer traced it to per-layer scalar synchronization — a diagnostic that
removed it restored ~103 tok/s from ~59. Unfixed in 0.7.1rc1.

jundot/omlx#4402 independently measures *this exact model and quant* on the
VLM engine at 20-27 tok/s aggregate, corroborating the figures above, and
reports VLM-engine concurrency scaling at ~1.2× across 8 requests against
~3.5× for LLM-engine models.

**That last number retires one of this change's two original justifications.**
The brief expected concurrency to stop the two agents serialising; on this
engine it largely will not. The case for oMLX here is the cache, and only the
cache — which is why the tables above are the deliverable and the decode
measurement is merely a gate it had to pass.

Not fixable from here: there is no vision-disable flag, and #3698 only helps
checkpoints that *lack* a vision tower. A vision-stripped Qwen3.8-27B
conversion would land on the LLM engine and should be markedly faster; none
exists among the published variants.

### Done means

1. ✅ **Alternating conversations are fast after the first call.** 1 s at 46k,
   14 s at 230k, and 6 s / 15 s after a full restart of the service. Measured,
   not inferred — `cached_tokens` reports 46,193 of 46,198 and 230,872 of
   230,877.
2. ✅ **Decode is within 5%** on realistic prose (26.1 against 27.5 tok/s),
   comfortably inside the ~10% bar, once both sides are compared
   generation-only.
3. ⬜ **Household chat is NOT verified**, and cannot be from here: Open WebUI's
   compose change reaches the apps VM by `git pull`, so it still points at the
   stopped Ollama. Prefix stability through its `/openai` passthrough is
   therefore also unmeasured — the one claim in this document resting on
   reasoning rather than measurement.
4. ✅ **The reconcile reports green**, with the summary naming the serving
   runtime.

A *reboot* has not been tested either. The login item is disabled so Ollama
will not come back alongside oMLX, and the oMLX agent is `RunAtLoad` +
`KeepAlive` — but that is an argument, not a measurement.

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
5b. ⬜ **Install and prove oMLX** — declared in `host/mac-mini/` as of
   2026-10-16, nothing on the box. The four criteria are in
   [Done means](#done-means); the two that can still fail are decode and the
   prefix stability of Open WebUI's passthrough.
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
