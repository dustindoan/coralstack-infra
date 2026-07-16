#!/usr/bin/env bash
# CoralStack Ente janitor run.
#
# WHY THIS EXISTS: when a file is emptied from Ente's trash, museum deletes the
# record and frees the user's quota immediately — but the S3/MinIO objects go
# into a `deleteObject` queue with a HARD-CODED 45-day delay before the cleanup
# cron will touch them (ente server pkg/repo/queue.go, DeleteObjectQueue).
# Nothing counts those purge-pending bytes against any quota, so upload/delete
# churn can hold disk for 45 days, unbounded. Ente's own self-hosting docs
# sanction expediting the queue by backdating `created_at`:
# https://ente.com/help/self-hosting/troubleshooting/misc
#
# THE POLICY (docs/ENTE_STORAGE.md): this job backdates only items older than
# JANITOR_MIN_AGE_DAYS (default 2), shrinking the effective purge window from
# 45 days to N days. Run it AFTER the nightly backup so every purged blob was
# captured by at least one restic snapshot — the backup history becomes the
# recovery buffer instead of Ente's queue delay. Museum's own cleanup cron
# then does the actual S3 deletion with all its bookkeeping intact; we never
# touch MinIO directly.
#
# --all flushes the whole queue regardless of age (the manual "expedite now"
# used by the admin panel / test workflow). --stats-only just reports.
set -euo pipefail

log()  { printf '[janitor] %s\n' "$*"; }
warn() { printf '[janitor] %s\n' "$*" >&2; }

: "${ENTE_DB_PASSWORD:?ENTE_DB_PASSWORD not set — is services/ente/.env present? (compose reads it via env_file)}"

MIN_AGE_DAYS="${JANITOR_MIN_AGE_DAYS:-2}"
[[ "$MIN_AGE_DAYS" =~ ^[0-9]+$ ]] || { warn "JANITOR_MIN_AGE_DAYS must be a whole number, got '$MIN_AGE_DAYS'"; exit 1; }
if (( MIN_AGE_DAYS < 1 )); then
	warn "JANITOR_MIN_AGE_DAYS=$MIN_AGE_DAYS: refusing to run with less than 1 day."
	warn "Below 1 day, blobs can be purged before the nightly backup ever saw them,"
	warn "leaving NO recovery path. Use 'janitor.sh --all' for a deliberate manual flush."
	exit 1
fi

MODE=scoped
case "${1:-}" in
	--all)        MODE=all ;;
	--stats-only) MODE=stats ;;
	"")           ;;
	*)            warn "unknown argument: $1 (expected --all or --stats-only)"; exit 1 ;;
esac

psql_ente() {
	PGPASSWORD="$ENTE_DB_PASSWORD" psql -h ente-postgres -U ente -d ente_db \
		-v ON_ERROR_STOP=1 -qAt -c "$1"
}

# Pending = emptied-from-trash objects museum hasn't purged yet. Sizes come
# from object_keys (rows are only marked is_deleted until the purge removes
# them). "Eligible" = already past the 45-day mark, i.e. what museum's cleanup
# cron (every 8 min, ≤5000 objects/run) will eat on its next passes.
stats() {
	psql_ente "
		SELECT count(*)
		    || '|' || coalesce(sum(ok.size), 0)
		    || '|' || coalesce(floor(max(now_utc_micro_seconds() - q.created_at) / 86400000000.0), 0)
		    || '|' || count(*) FILTER (WHERE q.created_at <= now_utc_micro_seconds() - (45::bigint * 24*60*60*1000000))
		FROM queue q
		LEFT JOIN object_keys ok ON ok.object_key = q.item
		WHERE q.queue_name = 'deleteObject' AND q.is_deleted = false;"
}

human_bytes() {
	awk -v b="$1" 'BEGIN{ s="B KiB MiB GiB TiB"; split(s,u); i=1
		while (b>=1024 && i<5) { b/=1024; i++ } printf "%.1f %s", b, u[i] }'
}

report() {
	local label="$1" line
	line="$(stats)"
	IFS='|' read -r count bytes oldest eligible <<<"$line"
	log "$label: ${count} objects pending ($(human_bytes "$bytes")), oldest ${oldest}d, ${eligible} already eligible"
	PENDING_COUNT="$count"; PENDING_BYTES="$bytes"
}

report "before"

if [[ "$MODE" != stats ]]; then
	# Backdate to 46 days so GetItemsReadyForDeletion sees the items on the
	# next cleanup run (the documented workaround's exact mechanism). The
	# scoped mode leaves items younger than MIN_AGE_DAYS alone — that's the
	# recovery buffer — and skips already-eligible rows to keep the count
	# honest. now_utc_micro_seconds() is museum's own SQL helper.
	age_filter="AND created_at <= now_utc_micro_seconds() - (${MIN_AGE_DAYS}::bigint * 24*60*60*1000000)
	            AND created_at >  now_utc_micro_seconds() - (45::bigint * 24*60*60*1000000)"
	[[ "$MODE" == all ]] && age_filter="AND created_at > now_utc_micro_seconds() - (45::bigint * 24*60*60*1000000)"

	expedited="$(psql_ente "
		WITH marked AS (
			UPDATE queue
			SET created_at = now_utc_micro_seconds() - (46::bigint * 24*60*60*1000000)
			WHERE queue_name = 'deleteObject' AND is_deleted = false
			${age_filter}
			RETURNING 1
		) SELECT count(*) FROM marked;")"

	if [[ "$MODE" == all ]]; then
		log "expedited ${expedited} objects (FULL FLUSH — 45-day buffer bypassed for all pending items)"
	else
		log "expedited ${expedited} objects older than ${MIN_AGE_DAYS} day(s)"
	fi
	report "after"
	log "museum's cleanup cron deletes ≤5000 objects per 8-minute run; watch: docker logs -f ente-museum 2>&1 | grep -i 'deleted file\\|cleanup'"
fi

# Dead-man's-switch + gauge: push to an Uptime Kuma push monitor (or
# healthchecks.io) so a silently failing janitor gets noticed, and the pending
# gauge lands in monitoring. Opt-in, same pattern as services/backup.
if [[ -n "${JANITOR_HEALTHCHECK_URL:-}" ]]; then
	msg="pending=${PENDING_COUNT} bytes=${PENDING_BYTES}"
	# -G appends the msg as a query param whether or not the URL already has
	# ones (Kuma push URLs ship with ?status=up&msg=OK&ping= baked in).
	if curl -fsS -m 10 --retry 3 -G "${JANITOR_HEALTHCHECK_URL}" --data-urlencode "msg=${msg}" >/dev/null 2>&1; then
		log "pinged healthcheck (${msg})"
	else
		warn "healthcheck ping failed (janitor run itself succeeded)"
	fi
fi

log "done."
