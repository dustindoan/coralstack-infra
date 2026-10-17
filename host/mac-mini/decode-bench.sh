#!/bin/bash
# Ollama decode baseline for the Mac mini. Server-side timings only
# (eval_count / eval_duration), so nothing here measures the network.
#
# TWO WORKLOADS, BECAUSE ONE OF THEM LIES. A first pass used only a "count to
# two hundred" prompt and measured 36.6 tok/s — but the server log showed MTP
# acceptance of 0.98-1.00 on it, against 0.83 on the household's real traffic.
# Counting is pathologically predictable, so it measures the best case for
# speculative decode rather than the typical one. `prose` asks for unrehearsed
# technical writing instead. Report both: the gap between them IS the MTP
# contribution, and a server whose MTP is broken shows up as the two
# converging.
set -uo pipefail
MODEL="${1:-qwen3.8:27b-nvfp4}"
GEN=512
URL=http://127.0.0.1:11434/api/generate
LOG="$HOME/.ollama/logs/server.log"

run() {                      # run <pad_bytes> <kind> <label>
	local pad="$1" kind="$2" label="$3" task
	local filler; filler="$(openssl rand -hex "$pad" | fold -w8 | paste -sd' ' -)"
	case "$kind" in
		count) task="Now count slowly from one to two hundred, in words, one number per line." ;;
		prose) task="Now write a detailed technical explanation, about six hundred words, of how copy-on-write snapshots work in a log-structured filesystem, including why write amplification matters and where fragmentation comes from. Prose only, no lists." ;;
	esac
	local body; body="$(jq -n --arg m "$MODEL" \
		--arg p "Here is some reference material: $filler

Ignore it. $task" --argjson n "$GEN" \
		'{model:$m, prompt:$p, stream:false, think:false,
		  options:{num_predict:$n, temperature:0}}')"
	local r; r="$(curl -sS -m 900 "$URL" -d "$body")"
	local acc; acc="$(grep '"speculative decode stats"' "$LOG" 2>/dev/null | tail -1 \
		| sed -n 's/.*acceptance=\([0-9.]*\).*/\1/p')"
	jq -r --arg l "$label" --arg acc "${acc:-n/a}" '
		(.prompt_eval_count // 0) as $pc | (.prompt_eval_duration // 1) as $pd |
		(.eval_count // 0) as $ec | (.eval_duration // 1) as $ed |
		[$l, $pc, (($pc / ($pd/1e9))|floor), $ec,
		 (($ec / ($ed/1e9))*10|floor|./10), $acc] | @tsv' <<<"$r"
}

printf 'label\tprompt_tok\tprefill_t/s\tgen_tok\tDECODE_t/s\tMTP_accept\n'
for i in 1 2 3; do run 400  count "count-short-$i"; done
for i in 1 2 3; do run 400  prose "prose-short-$i"; done
for i in 1 2;   do run 6000 prose "prose-12k-$i";   done
