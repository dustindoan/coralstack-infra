#!/usr/bin/env bash
# CoralStack backup run.
#
# Strategy: dump every database through its own engine first (raw file-copies
# of a live DB dir can be torn / inconsistent), then run ONE restic backup over
# the whole on-disk tree — service configs + the fresh dumps + photo blobs.
# That gives "the whole TerraMaster in one repo" plus a guaranteed-consistent
# database restore.
#
# Destination is whatever RESTIC_REPOSITORY points at: a local path (default)
# or an `rclone:remote:path` for cloud-agnostic offsite. See docs/BACKUPS.md.
set -euo pipefail

log()  { printf '\033[1;36m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[backup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[backup]\033[0m %s\n' "$*" >&2; exit 1; }

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set — this is a Tier-1 secret; see docs/BACKUPS.md}"

STAGING=/staging
DB_DIR="$STAGING/db"

# ─── Ensure the repository exists (idempotent) ───────────────────────────────
if ! restic cat config >/dev/null 2>&1; then
	log "Repository not initialized — running restic init at $RESTIC_REPOSITORY"
	restic init
fi

# ─── Consistent database dumps ───────────────────────────────────────────────
mkdir -p "$DB_DIR"
# Clear stale dumps so a removed service doesn't leave a phantom restore source.
rm -f "$DB_DIR"/*.dump "$DB_DIR"/*.sqlite 2>/dev/null || true

# Ente — Postgres, reached over the coralstack network (no Docker socket). The
# password comes from services/ente/.env via the compose env_file include.
if [[ -n "${ENTE_DB_PASSWORD:-}" ]]; then
	log "Dumping Ente Postgres (ente_db → ente_db.dump, custom format)"
	PGPASSWORD="$ENTE_DB_PASSWORD" pg_dump \
		-h ente-postgres -U ente -d ente_db -Fc \
		-f "$DB_DIR/ente_db.dump"
else
	warn "ENTE_DB_PASSWORD unset — skipping Ente Postgres dump (Ente not deployed?)"
fi

# Vaultwarden + Pocket ID — SQLite. The online .backup API is crash-consistent
# even with the app writing concurrently; opening read-only is belt-and-braces.
sqlite_backup() {
	local src="$1" dst="$2" name="$3"
	if [[ -f "$src" ]]; then
		log "Backing up $name SQLite → $(basename "$dst")"
		sqlite3 "file:${src}?mode=ro" ".backup '${dst}'"
	else
		warn "$src not found — skipping $name (service not deployed?)"
	fi
}
sqlite_backup /data/vaultwarden/db.sqlite3 "$DB_DIR/vaultwarden.sqlite" "Vaultwarden"

# Pocket ID's DB filename can vary by config; default is pocket-id.db. Glob the
# data dir so a non-default DB_CONNECTION_STRING still gets captured.
pocketid_db="$(ls -1 /data/pocket-id/*.db 2>/dev/null | head -1 || true)"
if [[ -n "$pocketid_db" ]]; then
	sqlite_backup "$pocketid_db" "$DB_DIR/pocket-id.sqlite" "Pocket ID"
else
	warn "No /data/pocket-id/*.db found — skipping Pocket ID (not deployed, or using Postgres?)"
fi

# ─── Build exclude list ──────────────────────────────────────────────────────
# Always exclude our own working dir (staging + restic cache + the local repo
# all live under /data/backup) so the backup never tries to capture itself.
# /config/data is the same tree as /data (don't capture it twice) and
# /config/.git lives on GitHub.
exclude_args=(--exclude /data/backup --exclude /config/data --exclude /config/.git)
if [[ -n "${BACKUP_EXCLUDES:-}" ]]; then
	IFS=',' read -ra _ex <<<"$BACKUP_EXCLUDES"
	for e in "${_ex[@]}"; do
		e="${e#"${e%%[![:space:]]*}"}"  # ltrim
		e="${e%"${e##*[![:space:]]}"}"  # rtrim
		[[ -n "$e" ]] && exclude_args+=(--exclude "$e")
	done
fi

# ─── Back up the tree as TWO snapshot streams ────────────────────────────────
# Same repo, two tagged streams with separate retention (see BACKUPS.md):
#   data    = /staging (fresh DB dumps) + /data (service configs + DBs) +
#             /config (compose tree incl. host-only services/*/.env secrets;
#             optional so older deployments without the mount still back up).
#             Deep history — it's tiny and every version matters.
#   storage = /storage (the TerraMaster: Ente photo blobs; bulk re-acquirable
#             media excluded by default). Blobs are append-then-delete, never
#             edited, so deep history buys nothing — short retention bounds
#             how long deleted-photo churn lingers in the repo. This pairs
#             with the Ente janitor's short purge window: docs/ENTE_STORAGE.md.
data_paths=(/staging /data)
[[ -d /config ]] && data_paths+=(/config)
log "Running restic backup (data stream) → $RESTIC_REPOSITORY"
restic backup \
	--tag data \
	--host "${COMMUNITY:-coralstack}" \
	"${exclude_args[@]}" \
	"${data_paths[@]}"

log "Running restic backup (storage stream) → $RESTIC_REPOSITORY"
restic backup \
	--tag storage \
	--host "${COMMUNITY:-coralstack}" \
	"${exclude_args[@]}" \
	/storage

# ─── Retention (per stream) ──────────────────────────────────────────────────
# forget both streams first, then prune once (prune is the expensive step).
# keep_args builds flags conditionally because restic rejects --keep-*=0; a
# blank/0 var simply omits that tier.
keep_args() {
	local daily="$1" weekly="$2" monthly="$3" args=()
	[[ "${daily:-0}"   -gt 0 ]] && args+=(--keep-daily   "$daily")
	[[ "${weekly:-0}"  -gt 0 ]] && args+=(--keep-weekly  "$weekly")
	[[ "${monthly:-0}" -gt 0 ]] && args+=(--keep-monthly "$monthly")
	(( ${#args[@]} )) && printf '%s\n' "${args[@]}"
	return 0
}
apply_retention() {
	local tag="$1" daily="$2" weekly="$3" monthly="$4"
	local -a keep
	mapfile -t keep < <(keep_args "$daily" "$weekly" "$monthly")
	if (( ${#keep[@]} == 0 )); then
		warn "All keep values for '$tag' stream are 0 — skipping forget (refusing to drop every snapshot)"
		return 0
	fi
	log "Applying retention policy ($tag: ${daily}d/${weekly}w/${monthly}m)"
	restic forget --tag "$tag" "${keep[@]}"
}
apply_retention data    "${RESTIC_KEEP_DAILY:-7}" "${RESTIC_KEEP_WEEKLY:-4}" "${RESTIC_KEEP_MONTHLY:-6}"
apply_retention storage "${RESTIC_STORAGE_KEEP_DAILY:-7}" "${RESTIC_STORAGE_KEEP_WEEKLY:-4}" "${RESTIC_STORAGE_KEEP_MONTHLY:-0}"

log "Pruning unreferenced data"
restic prune

# ─── Integrity check ─────────────────────────────────────────────────────────
# Metadata-only (fast). A periodic --read-data-subset is documented in BACKUPS.md.
log "Verifying repository structure (restic check)"
restic check

log "Backup complete."

# ─── Optional dead-man's-switch ──────────────────────────────────────────────
# Ping a monitoring URL (healthchecks.io, Uptime Kuma push, etc.) on success so
# a SILENTLY failing nightly backup gets noticed. Cloud-agnostic; opt-in.
if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
	if curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL" >/dev/null 2>&1; then
		log "Pinged healthcheck"
	else
		warn "Healthcheck ping failed (backup itself succeeded)"
	fi
fi
