#!/usr/bin/env bash
# CoralStack Mac mini reconcile — is the mini running what the repo says?
#
# WHY THIS EXISTS: the mini was the one host outside the deploy model. Renovate
# watched every container image on the NUC and nothing at all here, so Ollama
# sat three minor versions behind from June until a model pull failed on
# 2026-09-03. Its own updater could never have fixed that: the Mac app asks a
# human to click "Restart to update" in the menu bar, and this box is headless
# with auto-login. See docs/MAC_MINI.md.
#
# FOUR QUESTIONS, because they fail differently:
#   1. RUNTIME    — is Ollama reachable at all?
#   2. VERSION    — does the running app match the pin in versions.env?
#   3. ENV        — did the LaunchAgent's OLLAMA_* vars reach the RUNNING
#                   process? The Login Item can win the boot race and start an
#                   env-less Ollama that binds loopback only. It looks perfectly
#                   healthy from the mini and is invisible to Open WebUI.
#   4. MODELS     — declared in models.txt vs actually pulled.
#
# WHAT IT WILL AND WON'T DO ON ITS OWN. The mini is the one host where a bad
# update costs nothing (HARDWARE_FAILURE.md: "AI chat only ... nothing else
# depends on it"), so pulling models is automatic here in a way it never is on
# the NUC. Rewriting an executable and deleting data are not:
#   --apply        pull declared-but-missing models.       ← what the timer runs
#   (default)      report only; change nothing.
#   --prune        remove undeclared models. MANUAL ONLY — a 17 GB re-pull is a
#                  slow mistake to undo, and "undeclared" can just mean someone
#                  is mid-experiment and hasn't committed yet.
#   Upgrading Ollama itself is never done here. It replaces /Applications/
#   Ollama.app; a human runs `install.sh --upgrade-ollama`.
#
# ALERTING: pushes up/down + a one-line reason to an Uptime Kuma push monitor,
# same contract as services/smart/smart-check.sh and services/drift/
# drift-check.sh (MONITORING.md). Exits non-zero on any finding so a manual run
# reports through its exit status too.

# NOT `set -e`: findings are information to collect and report in one push, not
# a reason to abort partway and leave the monitor with no answer.
set -uo pipefail

log()  { printf '[ollama-reconcile] %s\n' "$*"; }
warn() { printf '[ollama-reconcile] %s\n' "$*" >&2; }

APPLY=0
PRUNE=0
for arg in "$@"; do
	case "$arg" in
		--apply)       APPLY=1 ;;
		--report-only) APPLY=0 ;;
		--prune)       PRUNE=1 ;;
		*) warn "unknown argument: $arg (expected --apply, --report-only, --prune)"; exit 1 ;;
	esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Config file is optional — the script must run straight from a repo checkout
# with no install, which is how you test it before touching the box.
ENV_FILE="${OLLAMA_RECONCILE_ENV:-$HERE/ollama.env}"
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck disable=SC1090
	set -a; . "$ENV_FILE"; set +a
fi

MODELS_FILE="${OLLAMA_MODELS_FILE:-$HERE/models.txt}"
VERSIONS_FILE="${OLLAMA_VERSIONS_FILE:-$HERE/versions.env}"
LABEL="${OLLAMA_HOST_LABEL:-mac-mini}"

# The Mac app's CLI. Not on a non-interactive SSH PATH, which is its own small
# trap: `ssh mini ollama list` fails with "command not found" on a box where
# Ollama is running perfectly.
OLLAMA_BIN="${OLLAMA_BIN:-}"
if [[ -z "$OLLAMA_BIN" ]]; then
	for candidate in /usr/local/bin/ollama /opt/homebrew/bin/ollama \
	                 /Applications/Ollama.app/Contents/Resources/ollama; do
		[[ -x "$candidate" ]] && { OLLAMA_BIN="$candidate"; break; }
	done
fi

FINDINGS=()
PULLED=()

# ─── 1. Runtime ──────────────────────────────────────────────────────────────
if [[ -z "$OLLAMA_BIN" ]]; then
	FINDINGS+=("no ollama binary found — is the Mac app installed?")
elif ! "$OLLAMA_BIN" list >/dev/null 2>&1; then
	FINDINGS+=("ollama is installed but not responding — the menu-bar app is probably not running (needs an auto-logged-in GUI session)")
	OLLAMA_BIN=""   # every check below depends on a live server
fi

if [[ -n "$OLLAMA_BIN" ]]; then

	# ─── 2. Version vs the pin ───────────────────────────────────────────
	if [[ -r "$VERSIONS_FILE" ]]; then
		want="$(sed -n 's/^OLLAMA_VERSION=//p' "$VERSIONS_FILE" | tr -d '"' | head -1)"
		# "ollama version is 0.30.10" -> 0.30.10
		have="$("$OLLAMA_BIN" --version 2>/dev/null | awk '{print $NF}' | head -1)"
		if [[ -n "$want" && -n "$have" && "$want" != "$have" ]]; then
			FINDINGS+=("ollama $have, repo pins $want — its own updater cannot apply this headless; run install.sh --upgrade-ollama")
		fi
	else
		FINDINGS+=("no versions.env at $VERSIONS_FILE — cannot check the ollama version pin")
	fi

	# ─── 3. Did the LaunchAgent env reach the running process? ───────────
	# The launchd domain having the vars is NOT enough: the process must have
	# been spawned after they were set. This is the check that catches the
	# Login-Item race in production rather than at install time.
	pid="$(pgrep -x ollama 2>/dev/null | head -1)"
	if [[ -n "$pid" ]]; then
		procenv="$(ps eww -p "$pid" 2>/dev/null | tr ' ' '\n')"
		missing=""
		for var in OLLAMA_HOST OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE OLLAMA_KEEP_ALIVE OLLAMA_NUM_PARALLEL; do
			grep -q "^${var}=" <<<"$procenv" || missing="${missing}${missing:+,}${var}"
		done
		if [[ -n "$missing" ]]; then
			FINDINGS+=("running ollama is missing env: $missing — the Login Item likely won the boot race; Open WebUI may see a loopback-only server. Restart: pkill -if Ollama.app; pkill -ix ollama; sleep 2; open -a Ollama")
		fi
	fi

	# ─── 4. Declared vs actual models ────────────────────────────────────
	if [[ ! -r "$MODELS_FILE" ]]; then
		FINDINGS+=("no models.txt at $MODELS_FILE — cannot reconcile the model set")
	else
		# `ollama list` first column, minus the header row.
		actual="$("$OLLAMA_BIN" list 2>/dev/null | awk 'NR>1 && NF {print $1}')"

		declared=""
		while IFS= read -r line; do
			line="${line%%#*}"                       # strip comments
			line="$(echo "$line" | tr -d '[:space:]')"
			[[ -n "$line" ]] && declared="${declared}${line}"$'\n'
		done < "$MODELS_FILE"

		# Missing: declared but not pulled.
		while IFS= read -r model; do
			[[ -z "$model" ]] && continue
			if ! grep -qxF "$model" <<<"$actual"; then
				if (( APPLY )); then
					log "pulling $model"
					if "$OLLAMA_BIN" pull "$model" 2>&1 | tail -3; then
						# `ollama pull` exits 0 even when it refuses — the
						# 0.30.10 client printed "Please download the latest
						# version" and exited clean. Verify by re-listing
						# rather than trusting the exit status.
						if "$OLLAMA_BIN" list 2>/dev/null | awk 'NR>1 && NF {print $1}' | grep -qxF "$model"; then
							PULLED+=("$model")
						else
							FINDINGS+=("pull of $model reported success but the model is not present — usually means the ollama client is too old for it")
						fi
					else
						FINDINGS+=("failed to pull $model")
					fi
				else
					FINDINGS+=("declared but not pulled: $model")
				fi
			fi
		done <<<"$declared"

		# Undeclared: pulled but not in the repo. Reported, never auto-removed.
		while IFS= read -r model; do
			[[ -z "$model" ]] && continue
			if ! grep -qxF "$model" <<<"$declared"; then
				if (( PRUNE )); then
					log "removing undeclared $model"
					"$OLLAMA_BIN" rm "$model" >/dev/null 2>&1 \
						|| FINDINGS+=("failed to remove $model")
				else
					FINDINGS+=("on the box but not in models.txt: $model (add it, or remove with --prune)")
				fi
			fi
		done <<<"$actual"
	fi
fi

# ─── Report ──────────────────────────────────────────────────────────────────
if [[ ${#FINDINGS[@]} -eq 0 ]]; then
	STATUS=OK
	extra=""
	if [[ ${#PULLED[@]} -gt 0 ]]; then
		joined="$(printf '%s, ' "${PULLED[@]}")"
		extra=" (pulled ${joined%, })"
	fi
	SUMMARY="$LABEL: ollama in sync with the repo${extra}"
else
	STATUS=DRIFT
	# Join on "; " explicitly. `IFS='; '` + ${FINDINGS[*]} would join on only the
	# FIRST character of IFS and read as "...pins 0.33.3;on the box but".
	joined="$(printf '%s; ' "${FINDINGS[@]}")"
	SUMMARY="$LABEL: ${joined%; }"
fi

if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
	push_status=up
	[[ "$STATUS" == OK ]] || push_status=down
	if curl -fsS -m 10 --retry 3 -G "$HEALTHCHECK_URL" \
		--data-urlencode "status=$push_status" \
		--data-urlencode "msg=${SUMMARY:0:400}" >/dev/null 2>&1; then
		log "pushed status=$push_status to healthcheck"
	else
		warn "healthcheck push failed (the reconcile itself completed: $STATUS)"
	fi
fi

log "$SUMMARY"
[[ "$STATUS" == OK ]] || exit 1
exit 0
