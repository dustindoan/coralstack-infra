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
# against. Exported, not passed as a flag, because --port is not a documented
# flag while OMLX_PORT is a documented variable.
export OMLX_PORT="${OMLX_PORT:-8000}"

MODEL_DIR="${OMLX_MODEL_DIR:-$HOME/.omlx/models}"
CACHE_DIR="${OMLX_SSD_CACHE_DIR:-$HOME/.omlx/cache}"
CACHE_MAX="${OMLX_SSD_CACHE_MAX_SIZE:-40GB}"
mkdir -p "$MODEL_DIR" "$CACHE_DIR"

exec "$OMLX_CLI" serve \
	--headless \
	--host 0.0.0.0 \
	--model-dir "$MODEL_DIR" \
	--paged-ssd-cache-dir "$CACHE_DIR" \
	--paged-ssd-cache-max-size "$CACHE_MAX" \
	--hot-cache-max-size 20% \
	--memory-guard balanced \
	--max-concurrent-requests 4 \
	"$@"

# ─── Why each flag ───────────────────────────────────────────────────────────
#
# --headless
#   Serves the inference AND admin APIs with no web UI. The admin API is how
#   the reconcile downloads a declared model, so headless is not a reduced
#   mode — it is the whole server minus a dashboard nobody can reach on a
#   headless box anyway.
#
# --host 0.0.0.0
#   Same exposure Ollama already has on 11434, except oMLX refuses a
#   non-loopback bind without an API key, so this is strictly an improvement
#   over the status quo rather than a new one. Binding the static 10.0.1.10
#   instead would be tighter but breaks if the lease ever moves.
#
# --paged-ssd-cache-max-size 40GB
#   NOT `auto`, which is 50% of free disk — ~400 GB here. 40 GB is the spike's
#   cap and about six 46k-token conversations at the measured 6.4 GB each
#   (2.9 GB of KV at 64 KB/token plus ~3.5 GB of Gated DeltaNet state
#   snapshots, ~150 MB per 2,048-token block). 0.7.0 is also the release that
#   stopped keeping one full-state tail per turn on GDN layouts, so this
#   figure depends on being on 0.7.0 or later.
#
# --hot-cache-max-size 20%
#   The upstream default, declared anyway so it is visible next to the
#   arithmetic that justifies it: ~9.6 GB of 48, on top of 15.45 GB of
#   weights, against a ~44 GiB wired ceiling. That headroom is what makes
#   "one runtime serves at a time" a hard constraint rather than a preference.
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
