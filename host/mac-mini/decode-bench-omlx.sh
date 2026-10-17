#!/bin/bash
# oMLX decode measurement — the counterpart to decode-bench.sh, deliberately
# the same shape so the numbers are comparable: same two workloads, same 512
# generated tokens, temperature 0, same unique random filler to defeat the
# prefix cache.
#
# `count` is predictable text and measures the best case for speculative
# decode; `prose` is unrehearsed and measures the typical case. On Ollama the
# gap between them was the MTP contribution (acceptance 0.99 vs 0.83). If oMLX
# shows no gap, its MTP is not engaging — which would mean the checkpoint's
# head is not being used, and that is the thing worth knowing.
set -uo pipefail
MODEL="${1:-Qwen3.8-27B-oQ4e-mtp}"
PORT="${2:-8000}"
GEN=512
KEY="$(sed -n 's/^OMLX_API_KEY=//p' "$HOME/.coralstack/omlx.env" | head -1)"
URL="http://127.0.0.1:${PORT}/v1/chat/completions"

run() {
	local pad="$1" kind="$2" label="$3" task
	local filler; filler="$(openssl rand -hex "$pad" | fold -w8 | paste -sd' ' -)"
	case "$kind" in
		count) task="Now count slowly from one to two hundred, in words, one number per line." ;;
		prose) task="Now write a detailed technical explanation, about six hundred words, of how copy-on-write snapshots work in a log-structured filesystem, including why write amplification matters and where fragmentation comes from. Prose only, no lists." ;;
	esac
	local body; body="$(jq -n --arg m "$MODEL" --arg c "Here is some reference material: $filler

Ignore it. $task" --argjson n "$GEN" \
		'{model:$m, messages:[{role:"user",content:$c}], stream:false,
		  temperature:0, max_tokens:$n}')"
	local t0 t1 r; t0="$(date +%s.%N)"
	r="$(curl -sS -m 900 "$URL" -H "Authorization: Bearer $KEY" \
		-H 'Content-Type: application/json' -d "$body")"
	t1="$(date +%s.%N)"
	# oMLX 0.7.x reports token rates on non-streaming responses; use its own
	# figure where present and the wall-clock derivation otherwise. Both are
	# printed so a disagreement is visible rather than silently averaged.
	jq -r --arg l "$label" --argjson wall "$(echo "$t1 - $t0" | bc)" '
		(.usage.prompt_tokens // 0) as $pt |
		(.usage.completion_tokens // 0) as $ct |
		(.usage.prompt_cached_tokens // .usage.prompt_tokens_details.cached_tokens // 0) as $cached |
		(.usage.completion_tokens_per_second // .usage.decode_tokens_per_second //
		 .timings.predicted_per_second // null) as $own |
		[ $l, $pt, $cached, $ct,
		  (if $own then ($own*10|floor|./10) else "n/a" end),
		  (($ct / $wall)*10|floor|./10) ] | @tsv' <<<"$r"
}

printf 'label\tprompt_tok\tcached\tgen_tok\toMLX_t/s\twall_t/s\n'
for i in 1 2 3; do run 400  count "count-short-$i"; done
for i in 1 2 3; do run 400  prose "prose-short-$i"; done
for i in 1 2;   do run 6000 prose "prose-12k-$i";   done
