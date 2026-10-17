#!/bin/zsh
# oMLX serve wrapper for the CoralStack Mac mini. The flags below ARE the
# desired state, so they live here in the repo rather than in the settings file
# the app rewrites. See docs/MAC_MINI.md.
#
# WHY A WRAPPER AND NOT A BARE plist. Two reasons, and the second is the real
# one. A plist cannot source a file, so the API key would have to sit in
# ~/Library/LaunchAgents as plaintext. And every flag below needs a sentence of
# justification, which a plist has nowhere to put.
#
# WHY THIS NEEDS NONE OF com.ollama.host.sh's GYMNASTICS, which is most of the
# point of the whole change. Ollama here is a menu-bar GUI app, so its five
# OLLAMA_* vars can only be delivered by `launchctl setenv` from an agent that
# races the Login Item, with a self-heal for when it loses. `omlx-cli serve
# --headless` is an ordinary foreground process serving the inference and admin
# APIs with no web UI, so launchd owns it directly with KeepAlive: no GUI app,
# no menu-bar icon, no Login Item, no boot race, no env agent, and no "Restart
# to update" button that a headless box never gets clicked.
#
# AND NOTHING HERE SELF-UPDATES. `omlx-cli` and the GUI binary `oMLX` are
# different executables in the same bundle; `strings` finds zero update-check
# symbols in the former against 6 in the latter (measured 2026-10-16). launchd
# runs the former, and install.sh keeps the bundle out of /Applications so the
# latter cannot be reached by a double-click. That is a structural property,
# not a convention someone has to remember.
set -u

STATE="${OMLX_STATE_DIR:-$HOME/.coralstack}"

# The API key, and anything overriding the defaults below.
ENV_FILE="${OMLX_ENV:-$STATE/omlx.env}"
if [[ -f "$ENV_FILE" ]]; then
	set -a; . "$ENV_FILE"; set +a
fi

if [[ -z "${OMLX_API_KEY:-}" ]]; then
	# Fail loudly rather than fall back to loopback. A server that came up
	# bound to 127.0.0.1 would look perfectly healthy from the mini and be
	# invisible to Open WebUI — the same silent-unreachable shape the Ollama
	# env race produces, and the reason that check exists in the reconcile.
	print -u2 "[omlx-serve] OMLX_API_KEY is empty in $ENV_FILE — refusing to start."
	print -u2 "[omlx-serve] oMLX will not bind a non-loopback host without a key."
	exit 78   # EX_CONFIG
fi

# The CLI inside the bundle. install.sh puts the bundle in ~/.coralstack on
# purpose (see above); the other candidates are there so a hand-installed copy
# still starts, because a box that boots is worth more than a tidy one.
OMLX_CLI="${OMLX_CLI:-}"
if [[ -z "$OMLX_CLI" ]]; then
	for candidate in \
		"$STATE/oMLX.app/Contents/MacOS/omlx-cli" \
		"$HOME/.omlx/bin/omlx" \
		/Applications/oMLX.app/Contents/MacOS/omlx-cli
	do
		[[ -x "$candidate" ]] && { OMLX_CLI="$candidate"; break; }
	done
fi
if [[ -z "$OMLX_CLI" ]]; then
	print -u2 "[omlx-serve] no omlx-cli found — run install.sh --install-omlx"
	exit 69   # EX_UNAVAILABLE
fi

# Pinned rather than left on the upstream default of 8000, so an upstream
# change cannot silently move the port Open WebUI and the client are configured
# against. Passed as --port, which 0.7.0's `serve --help` does list — an
# earlier draft of this file used the OMLX_PORT variable on the strength of the
# README, which documents a newer build than the pin.
OMLX_PORT="${OMLX_PORT:-8000}"

MODEL_DIR="${OMLX_MODEL_DIR:-$HOME/.omlx/models}"
CACHE_DIR="${OMLX_SSD_CACHE_DIR:-$HOME/.omlx/cache}"
CACHE_MAX="${OMLX_SSD_CACHE_MAX_SIZE:-300GB}"
HOT_CACHE_MAX="${OMLX_HOT_CACHE_MAX_SIZE:-1GB}"
mkdir -p "$MODEL_DIR" "$CACHE_DIR"

# ─── Settings that have no CLI flag ──────────────────────────────────────────
# Some knobs exist ONLY in ~/.omlx/settings.json, which the server rewrites on
# every startup. That is a hole in this file's "the flags are the desired
# state" model: anything set by hand there is undeclared, and the next restart
# may rewrite it. So the ones we care about are merged in here, before exec,
# which makes them repo-owned and survives the rewrite.
#
# gdn_sidecar_precision — the storage codec for Gated DeltaNet recurrent state,
#   which for this hybrid architecture is a large share of the cache. Options
#   are fp32|bf16|int8|rht_int8|rht_int16 (jundot/omlx#2644). The default fp32
#   is the most expensive; upstream #2700 measures bf16 at ~1.35x and rht_int8
#   at ~1.62x the resident block count for under 5% on warm prefill, and #3284
#   reports a sidecar bundle going 5.1GB -> 57MB.
# gdn_snapshot_storage — auto|ssd_sidecar|embedded. THE CODEC ONLY APPLIES ON
#   THE SIDECAR PATH: #2700 is open precisely because the `embedded` layout
#   stores state as raw fp32 and the codec never reaches it. So setting a codec
#   without forcing ssd_sidecar may do nothing at all.
GDN_PRECISION="${OMLX_GDN_PRECISION:-fp32}"
GDN_STORAGE="${OMLX_GDN_STORAGE:-auto}"
SETTINGS="${OMLX_SETTINGS_FILE:-$HOME/.omlx/settings.json}"

if command -v jq >/dev/null 2>&1; then
	mkdir -p "$(dirname "$SETTINGS")"
	[[ -s "$SETTINGS" ]] || printf '{}
' > "$SETTINGS"
	_tmp="$(mktemp)"
	if jq --arg prec "$GDN_PRECISION" --arg store "$GDN_STORAGE" \
		'.cache = ((.cache // {}) | .gdn_sidecar_precision = $prec | .gdn_snapshot_storage = $store)' \
		"$SETTINGS" > "$_tmp" 2>/dev/null; then
		mv "$_tmp" "$SETTINGS"
		print -u2 "[omlx-serve] settings: gdn_sidecar_precision=$GDN_PRECISION gdn_snapshot_storage=$GDN_STORAGE"
	else
		rm -f "$_tmp"
		print -u2 "[omlx-serve] WARNING: could not merge settings into $SETTINGS; continuing"
	fi
fi

exec "$OMLX_CLI" serve \
	--host 0.0.0.0 \
	--port "$OMLX_PORT" \
	--model-dir "$MODEL_DIR" \
	--paged-ssd-cache-dir "$CACHE_DIR" \
	--paged-ssd-cache-max-size "$CACHE_MAX" \
	--hot-cache-max-size "$HOT_CACHE_MAX" \
	--memory-guard aggressive \
	--max-concurrent-requests 4 \
	"$@"

# ─── Why each flag ───────────────────────────────────────────────────────────
#
# NO --headless, AND THE REASON IS A LESSON ABOUT READING DOCS. The README on
# the project's default branch documents `--headless` to serve the APIs without
# the web UI, and an earlier draft of this file passed it. It DOES NOT EXIST in
# 0.7.0 — `serve --help` on the installed binary lists every other flag here
# and not that one, so the README describes a newer build than the pin. The
# flag check in install.sh caught it before this became a KeepAlive crash loop,
# which is exactly what that check is for. Read the installed binary's help,
# not the docs for `main`.
#
# CONSEQUENCE WORTH KNOWING: 0.7.0 has no way to switch the UI off, so the
# admin dashboard at /admin and the chat UI at /admin/chat are served on the
# same port as the API. With --host 0.0.0.0 that is reachable from the
# household LAN. The API key is required for the API; whether a browser can
# reach /admin without it is verified separately and recorded in
# docs/MAC_MINI.md. If it is open, the options are a loopback bind plus a
# proxy, or moving the pin to 0.7.1 once that is a stable release.
#
# --host 0.0.0.0
#   Same exposure Ollama already has on 11434, except oMLX refuses a
#   non-loopback bind without an API key, so this is strictly an improvement
#   over the status quo rather than a new one. Binding the static 10.0.1.10
#   instead would be tighter but breaks if the lease ever moves.
#
# --paged-ssd-cache-max-size 300GB
#   NOT the default, which `serve --help` on 0.7.1rc1 gives as 100GB. (The
#   README says `auto`, meaning 50% of free disk, which would be ~400 GB here —
#   another place the docs for the default branch describe a different build.
#   Either way the default is far looser than this box needs.) 40 GB is the spike's
#   cap and about six 46k-token conversations at the measured 6.4 GB each
#   (2.9 GB of KV at 64 KB/token plus ~3.5 GB of Gated DeltaNet state
#   snapshots, ~150 MB per 2,048-token block). 0.7.0 is also the release that
#   stopped keeping one full-state tail per turn on GDN layouts, so this
#   figure depends on being on 0.7.0 or later.
#
# --hot-cache-max-size 1GB
#   DELIBERATELY SMALL, because this cache COMPETES WITH THE ACTIVE CONTEXT
#   and the active context matters far more.
#
#   What this tier is: an in-RAM holding area for the cache blocks of
#   conversations that are NOT currently generating. The active conversation's
#   KV is separate — the scheduler logs it as "Reserved prefill capacity".
#   So this is purely the fast lane for switching BACK to a recent
#   conversation without reading from SSD.
#
#   WHY IT IS NEARLY WORTHLESS HERE, from the 2026-10-16 spike's own rows:
#   "A after B" (served from RAM) took 2.9s and "A after a full oMLX restart"
#   (which clears RAM, so served from SSD) took 3.0s. One tenth of a second
#   between the tiers. The SSD tier is already fast enough that the RAM tier
#   buys essentially nothing.
#
#   AND IT WAS CAPPING THE CONTEXT. The guard reports max_bytes 33.6GB. Take
#   16.6GB of weights off that and ~17GB remains for caches, at a measured
#   61 KB per token:
#       hot cache 10GB -> ~114k tokens max context
#       hot cache  8GB -> ~147k
#       hot cache  2GB -> ~237k
#       hot cache ~0   -> ~262k, i.e. the model's own limit
#   A 10GB hot tier therefore silently capped this box at ~114k tokens to buy
#   a 0.1s improvement on switching. 1GB trades that away for the model's full
#   262,144-token context.
#
#   Absolute sizes only, and not optional: 0.7.1rc1 rejects the `20%` form the
#   README documents ("Invalid size string: 20%"), and its help gives the
#   default as "0 (disabled)", so omitting the flag switches the tier off.
#
# --memory-guard balanced
#   What the spike ran. 0.7.0 rebuilt the guard; `balanced` keeps ~8% of RAM
#   (3-8 GB) free for everything else on the box. `safe` would reserve 20%,
#   which this box does not need, and `aggressive` leaves 2%, which would put
#   the household's chat at the mercy of an agent's prefill.
#
# --max-concurrent-requests 4
#   Two long-lived agents, the household, and one spare. The upstream default
#   is 8. THIS IS THE UNTESTED AXIS: the spike called one conversation at a
#   time, so eviction under cap pressure and concurrent prefill behaviour are
#   both unmeasured. Note there is no priority or QoS — a member's chat queues
#   behind an agent's cold prefill, which is tolerable only because the point
#   of the change is that cold prefills stop happening after the first call.
#
# Deliberately NOT set:
#   server.gpu_keep_warm_interval — a settings.json key new in 0.7.0 that
#   holds the GPU out of its idle power state for up to 5 minutes after a
#   request. Left at default: it trades idle watts for first-token latency on
#   a box that is idle most of the day, and nothing has measured the trade.
