# Two agents on the Mac mini — where a turn's time actually goes

> **Status (2026-10-15):** Phase 1 complete and it changes the plan. Phases 2–4
> (hit-rate attribution, prompt restructure, oMLX verdict) are **not done** —
> this doc records the gate measurement and the method, so the next session
> starts from numbers instead of re-deriving them.

Companion to the design note *Mini inference baseline* (2026-10-14), which
established the hardware ceiling: prefill ~120 tok/s, a cache HIT 0.09 s, a
13.6 K-token MISS ~115 s. That note left one question open and it was the
important one: **on a realistic turn, does reasoning dominate prefill?**
Qwen3.8 defaults to `xhigh`, and at ~31 tok/s the 22 K-reasoning-token figure
from community reports would be ~12 minutes of thinking per turn, which would
make the whole prefill discussion a rounding error.

It does not. Measured below.

## The answer: reasoning is small, and the turn is bimodal

Three realistic turns, Letta-shaped prompt, tools attached, `num_predict`
uncapped, default thinking. Timings are Ollama's own server-side counters
(`prompt_eval_duration` / `eval_duration`), so the ssh tunnel contributes
nothing. Reasoning and visible tokens are counted **exactly**, by counting
streamed chunks — Ollama emits one chunk per token and tags thinking separately.

| turn | prompt tok | prefill | cache | reasoning tok | visible tok | decode | wall |
| --- | --- | --- | --- | --- | --- | --- | --- |
| admin / ops decision | 2,941 | 23.1 s | MISS | 221 | 27 | 11.8 s | **34.9 s** |
| admin / hard tradeoff | 3,021 | 0.78 s | HIT | 710 | 282 | 38.4 s | **39.2 s** |
| member / concierge | 2,389 | 3.9 s | partial | 154 | 0 | 8.4 s | **12.2 s** |

**Reasoning ran 154–710 tokens, not 22,000.** The model modulates: a trivial
"say one word" probe spent 23 reasoning tokens, the genuine architecture
tradeoff spent 710. Nothing observed is within an order of magnitude of the
12-minute scenario, so **`reasoning_effort` is not the emergency** the baseline
note feared it might be. It is still worth verifying it reaches the template
(Phase 3), but as an optimisation, not a rescue.

What the table actually shows is that a turn is **bimodal, and the cache
decides which mode you are in**:

- **MISS** — prefill dominates about 2:1 over decode (23.1 s vs 11.8 s).
- **HIT** — prefill collapses to 0.78 s and decode is the whole cost (38.4 s).

Both land at 35–39 s. That is the honest headline: at ~3 K tokens these turns
cost **tens of seconds, not minutes**, from either direction. The baseline's
115 s figure is a 13.6 K-token prompt; these agents are not there yet, and the
miss penalty scales with prompt size at a predictable tokens ÷ 120 seconds.

## The accidental finding: Letta invalidates its own cache with a timestamp

The first admin turn came back a **MISS** even though the identical system
prompt had been sent minutes earlier. The cause is in the prompt shape, not the
server: Letta compiles a metadata header into the system prompt,

```
### Memory [last modified: 2026-10-15 03:12:44 PM]
42 previous messages between you and the user are stored in recall memory
17 total memories you created are stored in archival memory
```

and that timestamp is regenerated **every turn**. It sits at roughly token
1,000 of a 2,941-token prompt, so it invalidates the prefix from there on and
drags everything after it — including the 1,144 tokens of tool schemas — back
through prefill.

This matters because it is a *strictly worse* problem than the one the design
note flagged. Core memory invalidating at position 0 at least requires somebody
to edit a memory. The metadata header invalidates on **every single turn, with
no memory edit at all**. Measured: ~2,776 tokens recomputed for a turn where
nothing the agent knows had changed.

It is also the cheapest thing on this list to fix, and it is a prompt-shape fix
that no inference server can make for you.

## Prompt budget, measured

| component | tokens | cumulative |
| --- | --- | --- |
| base instructions + memory blocks | 1,132 | 1,132 |
| tool schemas (9 tools) | 1,144 | 2,276 |
| conversation history (11 turns) | 665 | 2,941 |

Tool schemas are **39 % of the prompt** and they are perfectly stable — they
change only when the agent's toolset changes. Any mutable state ordered ahead
of them pays to re-prefill them. That is the Phase 3 restructure in one line:
**stable instructions → tool schemas → mutable memory → history.**

## Method, and two traps worth inheriting

Harness pattern as in the baseline note, with additions:

- **Assert the endpoint version before every run.** This machine runs its own
  Ollama 0.35.1 on `127.0.0.1:11434`. A previously-opened tunnel
  (`-L 11434:localhost:11434 mac-mini`) **lost the bind race and failed
  silently**, so curl to 11434 answers from the laptop, not the mini. Use a
  distinct local port and refuse to run unless `/api/version` reports the
  mini's pinned `0.40.4`. (The 2026-10-14 baseline is unaffected — the laptop
  has no `qwen3.8:27b-nvfp4`, so those runs could only have been served by the
  mini.)
- **Derive recomputed tokens from prefill time**, not from `prompt_eval_count`:
  `recomputed ≈ prefill_seconds × 120`. Ollama reports the full prompt length
  on a hit, so only duration distinguishes hit from miss — and this trick
  locates *where* the prefix broke, which is what attribution needs.
- Report measured `prompt_eval_count`, never the intended label.

**Known gap in the accounting:** `eval_count` exceeds counted thinking+visible
chunks (365 vs 248 on turn 1) because tool-call tokens arrive in `tool_calls`
rather than `content`. The member turn emitted **0 visible tokens** — it replied
entirely through a `send_message` tool call. Reasoning counts above are exact;
the visible column undercounts wherever a tool call carried the reply.

## Host facts (measured 2026-10-15)

```
qwen3.8:27b-nvfp4   28 GB   100% GPU   CONTEXT 32768   RUNNER mlx   UNTIL Forever
48 GiB physical, iogpu.wired_limit_mb = 45056 (44 GiB)
OLLAMA_NUM_PARALLEL=2  OLLAMA_KV_CACHE_TYPE=q8_0  OLLAMA_FLASH_ATTENTION=1  KEEP_ALIVE=-1
```

Prefill measured at **127 tok/s** across four prompt sizes — consistent with the
baseline's post-upgrade 121–127, confirming the hardware ceiling independently.

## What is NOT done

- **Phase 2 — hit-rate attribution.** Specifically the clean agent-switch
  experiment: run agent A, run agent B, return to A *without* editing A's
  memory, and see whether A comes back at 0.09 s or pays a full prefill. With
  `OLLAMA_NUM_PARALLEL=2` both agents may already hold their own slot, in which
  case switching costs nothing and the eviction argument does not bite yet.
  Also unmeasured: where the residency ceiling actually falls (weights 18.5 GB,
  steady state 33 GB, limit 44 GiB) for the context sizes two agents need.
- **Phase 3** — whether `reasoning_effort` reaches the built-in renderer, and
  the prompt restructure above. Note the template is **not inspectable**:
  `ollama show --modelfile` reports `TEMPLATE {{ .Prompt }}` with
  `RENDERER qwen3.8`, i.e. the chat template is compiled into Ollama's Go code,
  so this can only be tested behaviourally (does `think` change `eval_count`).
- **Phase 4 — oMLX.** Not evaluated. One early capability probe: the Ollama
  binary contains no `slot-save` / `prompt-cache` strings, which is *suggestive*
  that Ollama cannot persist a KV cache, but the route enumeration came back
  empty so this is **not conclusive** and should be settled properly. The
  maintenance and Renovate-trackability questions were blocked by a web-search
  rate limit and remain open.

## A scoping note

The task that produced this doc described the two agents as "clinician-facing"
and "patient-facing". That does not match this project — CoralStack's two
planned roles are the **admin-facing** agent (lettabot) and the **member-facing
concierge**, per the admin-agent design note and docs/AGENT.md. This doc assumes
admin/member. The measurements are domain-independent, so nothing above changes
if the wording was deliberate, but somebody should confirm which was meant.

Letta itself is **not deployed** — docs/AGENT.md lists it as a candidate
runtime, with "does memory earn its complexity?" still an open question. These
measurements reproduce the *shape* of a Letta prompt rather than calling a live
Letta, because what drives the economics is the position of mutable state, not
the wording.
