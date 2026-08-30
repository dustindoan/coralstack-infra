#!/usr/bin/env bash
# Entrypoint: run the scheduled drift check under supercronic, OR pass through
# a one-shot command for manual ops. supercronic inherits this process's
# environment, so the cron job sees HEALTHCHECK_URL, DRIFT_* etc.
set -euo pipefail

case "${1:-cron}" in
	cron)
		# Daily is the right cadence: drift is created by a human at a keyboard,
		# not by a process, so sub-hourly polling buys nothing and just adds
		# noise. Runs at 06:10 — ahead of the SMART check at 06:20, so if the
		# morning brings two alerts you read them in causal order.
		: "${DRIFT_CRON:=10 6 * * *}"
		printf '%s /usr/local/bin/drift-check.sh\n' "$DRIFT_CRON" >/etc/crontab
		echo "[drift] scheduled: '${DRIFT_CRON}'  (TZ=${TZ:-UTC})"
		echo "[drift] watching: ${DRIFT_REPO_PATH:-/repo} (expected branch: ${DRIFT_EXPECTED_BRANCH:-main})"
		echo "[drift] run manually with: docker exec drift drift-check.sh"

		# Run once at startup so a broken mount or an unreachable origin shows
		# up in `docker logs drift` now, not at 06:10 tomorrow. A drift finding
		# here is a real finding, not a startup error — it exits non-zero on
		# purpose, so don't let that kill the container before cron starts.
		/usr/local/bin/drift-check.sh || true

		# Absolute path: supercronic as PID 1 re-execs itself via argv[0]; a
		# bare name makes that re-exec fail and crash-loop (same footgun as
		# services/backup and services/smart — see their entrypoints).
		exec /usr/local/bin/supercronic /etc/crontab
		;;
	check|drift-check.sh) exec /usr/local/bin/drift-check.sh ;;
	*)                    exec "$@" ;;
esac
