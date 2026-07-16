#!/usr/bin/env bash
# Entrypoint: run the scheduled janitor under supercronic, OR pass through a
# one-shot command for manual ops. supercronic inherits this process's
# environment, so the cron job sees ENTE_DB_PASSWORD, JANITOR_*, etc.
set -euo pipefail

case "${1:-cron}" in
	cron)
		# Default: daily at 05:30, AFTER the nightly backup (03:15). Ordering
		# matters — see docs/ENTE_STORAGE.md: purging only after the backup ran
		# guarantees every deleted blob was captured by at least one snapshot,
		# so the restic history replaces Ente's 45-day recovery buffer.
		: "${JANITOR_CRON:=30 5 * * *}"
		printf '%s /usr/local/bin/janitor.sh\n' "$JANITOR_CRON" >/etc/crontab
		echo "[janitor] scheduled: '${JANITOR_CRON}'  (TZ=${TZ:-UTC})"
		echo "[janitor] min age: ${JANITOR_MIN_AGE_DAYS:-2} day(s)"
		echo "[janitor] run manually with: docker exec ente-janitor janitor.sh"
		# Absolute path: supercronic as PID 1 re-execs itself via argv[0]; a
		# bare name makes that re-exec fail and crash-loop (same footgun as
		# services/backup — see its entrypoint.sh).
		exec /usr/local/bin/supercronic /etc/crontab
		;;
	# Convenience pass-throughs for `docker exec ente-janitor <cmd>`:
	janitor|janitor.sh)  exec /usr/local/bin/janitor.sh ;;
	stats)               exec /usr/local/bin/janitor.sh --stats-only ;;
	expedite-all)        exec /usr/local/bin/janitor.sh --all ;;
	*)                   exec "$@" ;;
esac
