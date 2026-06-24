#!/usr/bin/env bash
# Entrypoint: run scheduled backups under supercronic, OR pass through a
# one-shot command for manual ops. supercronic inherits this process's
# environment, so the cron job sees RESTIC_*, ENTE_DB_PASSWORD, etc. without
# the env-file dance busybox crond would force on us.
set -euo pipefail

case "${1:-cron}" in
	cron)
		: "${BACKUP_CRON:=15 3 * * *}"
		printf '%s /usr/local/bin/backup.sh\n' "$BACKUP_CRON" >/etc/crontab
		echo "[backup] scheduled: '${BACKUP_CRON}'  (TZ=${TZ:-UTC})"
		echo "[backup] repository: ${RESTIC_REPOSITORY:-<unset>}"
		echo "[backup] run a manual backup with: docker exec backup backup.sh"
		# Invoke supercronic by ABSOLUTE path: as PID 1 it re-execs itself to
		# set up the process reaper, using argv[0]. A bare name (resolved via
		# PATH) leaves argv[0] non-absolute, so the re-exec fails with
		# "Failed to fork exec: no such file or directory" and the container
		# crash-loops. The absolute path makes the self-re-exec resolve.
		exec /usr/local/bin/supercronic /etc/crontab
		;;
	# Convenience pass-throughs for `docker exec backup <cmd>` (see BACKUPS.md):
	backup|backup.sh)  exec /usr/local/bin/backup.sh ;;
	snapshots)         exec restic snapshots ;;
	restic)            shift; exec restic "$@" ;;
	*)                 exec "$@" ;;
esac
