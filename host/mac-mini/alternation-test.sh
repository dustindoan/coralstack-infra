#!/bin/bash
# THE measurement this whole change exists for: do two long conversations stop
# evicting each other?
#
# Ollama's MLX runner keeps ONE prompt-prefix cache, so alternating between two
# ~46k-token agents costs a full cold prefill every switch (~7 minutes, logged
# 2026-10-07). oMLX keeps a paged per-conversation cache and spills it to SSD.
#
# Reads prompt_tokens_details.cached_tokens, which is oMLX's own report of how
# much of the prompt it did not have to recompute.
set -uo pipefail
MODEL="${1:-Qwen3.8-27B-oQ4e-mtp}"
PORT="${2:-8000}"
KEY="$(sed -n 's/^OMLX_API_KEY=//p' "$HOME/.coralstack/omlx.env" | head -1)"
URL="http://127.0.0.1:${PORT}/v1/chat/completions"
W=/tmp/alt-work; mkdir -p "$W"

# Two distinct ~46k-token conversations. Generated ONCE and reused, because the
# whole point is that the prefix is byte-identical across calls.
for c in A B; do
	[[ -f "$W/filler-$c" ]] || openssl rand -hex 120000 | fold -w7 | paste -sd' ' - > "$W/filler-$c"
done

# call <conv> <extra-turns> <label>
call() {
	local c="$1" extra="$2" label="$3"
	local msgs
	msgs="$(jq -n --rawfile f "$W/filler-$c" --argjson n "$extra" '
		[ {role:"user", content:("Reference dossier \($f)")},
		  {role:"assistant", content:"Noted. I have read the dossier."} ]
		+ ( [range($n)] | map({role:"user", content:"Continue. Reply with one word."})
		    | map(., {role:"assistant", content:"Acknowledged."}) | flatten )
		+ [ {role:"user", content:"Reply with exactly one word."} ]')"
	local body; body="$(jq -n --arg m "$MODEL" --argjson ms "$msgs" \
		'{model:$m, messages:$ms, stream:false, temperature:0, max_tokens:1}')"
	local t0 t1 r; t0="$(date +%s)"
	r="$(curl -sS -m 1800 "$URL" -H "Authorization: Bearer $KEY" \
		-H 'Content-Type: application/json' -d "$body")"
	t1="$(date +%s)"
	jq -r --arg l "$label" --argjson wall "$((t1 - t0))" '
		[$l, (.usage.prompt_tokens // 0),
		 (.usage.prompt_tokens_details.cached_tokens // 0),
		 ($wall | tostring + "s")] | @tsv' <<<"$r"
}

printf 'step\tprompt_tok\tCACHED\twall\n'
call A 0 "A cold"
call A 1 "A + one turn"
call B 0 "B cold"
call A 1 "A after B    <- the eviction test"

echo "--- restarting oMLX to test cache PERSISTENCE ---" >&2
launchctl kickstart -k "gui/$(id -u)/com.coralstack.omlx" >&2
for _ in $(seq 1 60); do
	curl -fsS -m 5 -o /dev/null -H "Authorization: Bearer $KEY" \
		"http://127.0.0.1:${PORT}/v1/models" 2>/dev/null && break
	sleep 3
done
call A 1 "A after restart"
