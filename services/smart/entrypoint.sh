#!/usr/bin/env bash
# Entrypoint: run the scheduled SMART checks under supercronic, OR pass through
# a one-shot command for manual ops. supercronic inherits this process's
# environment, so the cron jobs see SMART_DEVICES, HEALTHCHECK_URL, etc.
set -euo pipefail

case "${1:-cron}" in
	cron)
		# Two schedules, deliberately:
		#   - a DAILY attribute check, because a sector count that went from 0
		#     to nonzero is the warning, and waiting a week to see it wastes
		#     most of the notice the drive is giving you;
		#   - a WEEKLY full dump (--full) into the logs, which is the thing you
		#     actually want to read back when deciding "is this drive trending
		#     worse, or has it been like that since we bought it?".
		: "${SMART_CRON:=20 6 * * *}"        # daily 06:20, after the 05:30 janitor
		: "${SMART_FULL_CRON:=40 6 * * 0}"   # Sundays 06:40
		{
			printf '%s /usr/local/bin/smart-check.sh\n'        "$SMART_CRON"
			printf '%s /usr/local/bin/smart-check.sh --full\n' "$SMART_FULL_CRON"
		} >/etc/crontab
		echo "[smart] scheduled: daily '${SMART_CRON}', full '${SMART_FULL_CRON}'  (TZ=${TZ:-UTC})"
		echo "[smart] devices: ${SMART_DEVICES:-<unset — will scan>}"
		echo "[smart] run manually with: docker exec smart smart-check.sh"

		# Fail fast and loudly if the container can't actually read the disks.
		# A SMART monitor that silently sees nothing is worse than none at all:
		# it manufactures the feeling of coverage without the coverage. The
		# check runs once at startup so a broken device/cap setup surfaces in
		# `docker logs smart` immediately rather than at 06:20 tomorrow.
		if ! /usr/local/bin/smart-check.sh; then
			echo "[smart] WARNING: the startup check did not come back clean." >&2
			echo "[smart] If it says 'cannot read SMART data' or 'No devices to check'," >&2
			echo "[smart] this is a permissions/device problem, NOT a disk problem —" >&2
			echo "[smart] see services/smart/docker-compose.yml and docs/MONITORING.md." >&2
		fi

		# Absolute path: supercronic as PID 1 re-execs itself via argv[0]; a
		# bare name makes that re-exec fail and crash-loop (same footgun as
		# services/backup — see its entrypoint.sh).
		exec /usr/local/bin/supercronic /etc/crontab
		;;
	# Convenience pass-throughs for `docker exec smart <cmd>`:
	check|smart-check.sh) exec /usr/local/bin/smart-check.sh ;;
	full)                 exec /usr/local/bin/smart-check.sh --full ;;
	report)               exec cat "${SMART_REPORT_PATH:-/var/lib/smart/report.txt}" ;;
	*)                    exec "$@" ;;
esac
