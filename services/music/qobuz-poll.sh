#!/bin/bash
# Qobuz acquisition poll loop — the hands-off front half.
#
# Every QOBUZ_POLL_INTERVAL seconds, runs qobuz-fetch.py, which enumerates
# your Qobuz purchases and downloads any you don't already have (tracked by
# the persistent watermark at QOBUZ_STATE) into QOBUZ_DEST. music-ingest then
# imports them and Jellyfin's real-time monitor surfaces them. Net effect:
# buy an album → it appears in Jellyfin a few minutes later, untouched.
#
# Env (from services/music/.env + compose):
#   QOBUZ_TOKEN          web-session token (REQUIRED to do anything)
#   QOBUZ_POLL_INTERVAL  seconds between polls (default 900 = 15 min)
#   QOBUZ_DEST           staging dir (default /staging)
#   QOBUZ_STATE          watermark file (set by compose to /state/fetched.json)
#
# Token refresh: the token is read from the environment at container start, so
# after re-extracting a fresh one into services/music/.env, reload with
#   docker compose up -d qobuz-poll
set -uo pipefail

INTERVAL="${QOBUZ_POLL_INTERVAL:-900}"
DEST="${QOBUZ_DEST:-/staging}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "qobuz-poll up: polling every ${INTERVAL}s → ${DEST} (watermark: ${QOBUZ_STATE:-none})"

while true; do
    if [[ -z "${QOBUZ_TOKEN:-}" ]]; then
        log "WARNING: QOBUZ_TOKEN unset — add it to services/music/.env and run" \
            "'docker compose up -d qobuz-poll'. Idling."
    else
        log "polling purchases…"
        # qobuz-fetch prints per-track results; exit 1 on any failure
        # (incl. a 401 from an expired token, with a re-auth hint).
        if ! python /app/qobuz-fetch.py "$DEST"; then
            log "WARNING: fetch reported errors (expired token? see message above)." \
                "Retrying next cycle; refresh the token in .env if this persists."
        fi
    fi
    sleep "$INTERVAL"
done
