#!/usr/bin/env bash
# CoralStack deploy-drift check — is the box actually running what the repo says?
#
# The deploy model is one-way: changes flow repo -> box via `git pull`, and the
# box is a pull-only target. Nothing enforced that. On 2026-08-28 the box sat on
# a feature branch with three commits that existed on no other machine — the
# only copy of that day's incident writeup lived on the disk the incident was
# about. A routine `git pull` reported success and fetched nothing, because the
# branch had no upstream. That is the failure this check exists to catch.
#
# DEPLOY_ARCHITECTURE.md already names the mirror-image gap, merged-but-not-
# deployed, and specs a deploy primitive for it. This is the other direction:
# deployed-but-not-merged. Both are drift; only one was instrumented.
#
# Deliberately READ-ONLY. It never fetches, never checks out, never pushes —
# it reads local git state and asks the remote one question with `git ls-remote`
# (anonymous; the repo is public). A monitor that can mutate the deploy tree is
# a worse problem than the drift it watches. That is also why the repo is
# mounted `:ro`: a fetch would need to write to .git.
#
# ALSO WATCHES AUTOKUMA. Same question, one layer up: the repo declares a
# monitor set, AutoKuma is what makes Kuma match it. On 2026-08-30 AutoKuma sat
# disconnected for ~2 hours after Uptime Kuma was restarted — ~1,400 failed
# syncs, WARN every 5s, container still `Up`, monitors still green. Only the
# declarative layer was dead, and nothing noticed. Any Kuma restart (update,
# reboot, power cut) reproduces it.
#
# Two signals, because they fail differently:
#   - LIVENESS: AutoKuma rewrites its own state file (${AUTOKUMA_DATA}/data/
#     autokuma.db/db) every sync cycle, ~10s. A stale mtime means it is not
#     syncing, even when nothing needs changing. This is the one that catches
#     the 2026-08-30 case.
#   - AGREEMENT: the count of monitor files in the repo vs monitors actually in
#     Kuma. Catches a monitor added by hand in the UI, a setup.sh that was never
#     re-run, and a pending change AutoKuma never applied.
#
# Both are SKIPPED cleanly when their mounts are absent, so this script still
# runs anywhere — same host-agnostic property as services/smart/smart-check.sh.
#
# ALERTING: pushes to HEALTHCHECK_URL (an Uptime Kuma push monitor) with an
# explicit up/down and the reason, mirroring services/smart/smart-check.sh. If
# this script stops running, the heartbeat lapses and Kuma alerts on that too.
#
# Exits non-zero on drift, so a manual run reports through its exit status.

set -uo pipefail

REPO="${DRIFT_REPO_PATH:-/repo}"
EXPECTED_BRANCH="${DRIFT_EXPECTED_BRANCH:-main}"
LABEL="${DRIFT_HOST_LABEL:-apps-vm}"
AUTOKUMA_DATA="${DRIFT_AUTOKUMA_DATA:-/autokuma}"
KUMA_DB="${DRIFT_KUMA_DB:-/kuma/kuma.db}"
MONITOR_DIR="${DRIFT_MONITOR_DIR:-$REPO/services/autokuma/monitors}"
# Sync cycle is ~10s. 600s tolerates a restart or a slow reconcile without
# crying wolf, while still catching a stall the same morning.
STALE_AFTER="${DRIFT_AUTOKUMA_STALE_AFTER:-600}"

log()  { echo "[drift] $*"; }
warn() { echo "[drift] WARNING: $*" >&2; }

FINDINGS=()

# git refuses to operate in a directory owned by another user unless told the
# repo is trusted. The mount is read-only, so this grants nothing.
git config --global --add safe.directory "$REPO" 2>/dev/null || true

if [[ ! -d "$REPO/.git" ]]; then
	SUMMARY="$LABEL: no git repo at $REPO — cannot verify what is deployed"
	warn "$SUMMARY"
	STATUS=FAIL
else
	cd "$REPO" || exit 2

	branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
	head_sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

	# 1. On the expected branch? This is the 2026-08-28 case exactly.
	if [[ "$branch" != "$EXPECTED_BRANCH" ]]; then
		FINDINGS+=("on branch '$branch', expected '$EXPECTED_BRANCH'")
	fi

	# 2. Uncommitted edits to tracked files. Untracked files are excluded on
	#    purpose: the box legitimately carries untracked, gitignored per-service
	#    .env files, and flagging those would make this monitor cry wolf daily —
	#    which is how a monitor gets muted and stops being a monitor.
	if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
		n="$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
		FINDINGS+=("$n uncommitted change(s) to tracked files")
	fi

	# 3. Does the deployed commit exist on the remote at all?
	#    One question, no fetch. If HEAD doesn't match the remote branch tip,
	#    the box is either behind (merged-but-not-deployed) or ahead (commits
	#    that exist nowhere else). Both are actionable; both mean the repo is
	#    not a truthful record of what is running.
	remote_sha="$(GIT_TERMINAL_PROMPT=0 git ls-remote origin "refs/heads/$EXPECTED_BRANCH" 2>/dev/null | awk '{print $1}')"
	if [[ -z "$remote_sha" ]]; then
		FINDINGS+=("could not reach origin to compare (network? auth?)")
	elif [[ "$head_sha" != "$remote_sha" ]]; then
		# Distinguish the two directions using only local history. If the
		# remote tip is an ancestor of HEAD, we have commits it doesn't —
		# the dangerous direction, because they may exist only here.
		if git merge-base --is-ancestor "$remote_sha" HEAD 2>/dev/null; then
			ahead="$(git rev-list --count "$remote_sha"..HEAD 2>/dev/null || echo '?')"
			FINDINGS+=("$ahead commit(s) NOT PUSHED — they exist only on this box")
		elif git cat-file -e "$remote_sha^{commit}" 2>/dev/null && git merge-base --is-ancestor HEAD "$remote_sha" 2>/dev/null; then
			behind="$(git rev-list --count HEAD.."$remote_sha" 2>/dev/null || echo '?')"
			FINDINGS+=("$behind commit(s) behind origin/$EXPECTED_BRANCH — merged but not deployed")
		else
			# Local objects don't contain the remote tip, so the direction
			# can't be settled without fetching. Say that plainly rather than
			# guessing: "diverged" is honest, "behind" would be a claim.
			FINDINGS+=("HEAD ${head_sha:0:7} differs from origin/$EXPECTED_BRANCH ${remote_sha:0:7}")
		fi
	fi

	# ─── AutoKuma: is the declarative layer actually running? ─────────────
	# Skipped, not failed, when the mount is absent — this script runs on hosts
	# that have no AutoKuma.
	akdb="$AUTOKUMA_DATA/data/autokuma.db/db"
	if [[ -f "$akdb" ]]; then
		# GNU/busybox use -c %Y, BSD uses -f %m. Try both, and NEVER fall back
		# to 0: a failed stat would compute an age of ~the whole Unix epoch and
		# report a confident, entirely fictional stall. A monitor that invents a
		# fault costs the same trust as one that misses a real one.
		mtime="$(stat -c %Y "$akdb" 2>/dev/null || stat -f %m "$akdb" 2>/dev/null || true)"
		if [[ -z "$mtime" || ! "$mtime" =~ ^[0-9]+$ ]]; then
			FINDINGS+=("could not read AutoKuma's heartbeat mtime at $akdb (stat unsupported?)")
		else
			age=$(( $(date +%s) - mtime ))
			if (( age > STALE_AFTER )); then
				FINDINGS+=("AutoKuma has not synced in ${age}s (>${STALE_AFTER}s) — config-as-code is stalled, check 'docker logs autokuma' for EngineIO errors")
			fi
		fi
	fi

	# ─── AutoKuma: does Kuma agree with the repo? ─────────────────────────
	# Counts the monitor files in the REPO, not the rendered copy under
	# ${DATA_PATH} — comparing against the repo also catches a setup.sh that
	# was never re-run after a pull.
	if [[ -d "$MONITOR_DIR" && -r "$KUMA_DB" ]]; then
		declared="$(find "$MONITOR_DIR" -maxdepth 1 -type f \( -name '*.toml' -o -name '*.toml.template' \) 2>/dev/null | wc -l | tr -d ' ')"
		# A read failure here is not drift — say so rather than alarming.
		if actual="$(sqlite3 "$KUMA_DB" 'select count(*) from monitor;' 2>/dev/null)" && [[ -n "$actual" ]]; then
			if [[ "$declared" != "$actual" ]]; then
				FINDINGS+=("monitor set disagrees: $declared declared in repo, $actual live in Kuma")
			fi
		else
			FINDINGS+=("could not read Kuma's monitor table (db locked or schema changed?)")
		fi
	fi

	if [[ ${#FINDINGS[@]} -eq 0 ]]; then
		STATUS=OK
		extra=""
		[[ -f "$akdb" ]] && extra=" + autokuma live"
		SUMMARY="$LABEL: in sync with origin/$EXPECTED_BRANCH @ ${head_sha:0:7}${extra}"
	else
		STATUS=DRIFT
		# Join with "; ". Not `IFS='; '` + ${FINDINGS[*]} — that joins on only
		# the FIRST character of IFS, which reads as "...expected 'main';1 commit".
		joined="$(printf '%s; ' "${FINDINGS[@]}")"
		SUMMARY="$LABEL: ${joined%; }"
	fi
fi

# ─── Push to the monitor ─────────────────────────────────────────────────────
if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
	push_status=up
	[[ "$STATUS" == OK ]] || push_status=down
	if curl -fsS -m 10 --retry 3 -G "$HEALTHCHECK_URL" \
		--data-urlencode "status=$push_status" \
		--data-urlencode "msg=${SUMMARY:0:400}" >/dev/null 2>&1; then
		log "pushed status=$push_status to healthcheck"
	else
		warn "healthcheck push failed (the drift check itself completed: $STATUS)"
	fi
fi

log "$SUMMARY"
[[ "$STATUS" == OK ]] || exit 1
exit 0
