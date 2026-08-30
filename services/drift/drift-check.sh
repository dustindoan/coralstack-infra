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
# ALERTING: pushes to HEALTHCHECK_URL (an Uptime Kuma push monitor) with an
# explicit up/down and the reason, mirroring services/smart/smart-check.sh. If
# this script stops running, the heartbeat lapses and Kuma alerts on that too.
#
# Exits non-zero on drift, so a manual run reports through its exit status.

set -uo pipefail

REPO="${DRIFT_REPO_PATH:-/repo}"
EXPECTED_BRANCH="${DRIFT_EXPECTED_BRANCH:-main}"
LABEL="${DRIFT_HOST_LABEL:-apps-vm}"

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

	if [[ ${#FINDINGS[@]} -eq 0 ]]; then
		STATUS=OK
		SUMMARY="$LABEL: in sync with origin/$EXPECTED_BRANCH @ ${head_sha:0:7}"
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
