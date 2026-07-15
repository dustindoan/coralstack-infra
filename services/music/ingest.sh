#!/bin/bash
# CoralStack music ingest loop — staging → beets → library → Jellyfin scan.
#
# Watches /staging for dropped audio files. When the drop has gone quiescent
# (no file modified for QUIESCENCE_SECONDS — so we never import a half-copied
# album), runs a quiet beets import which tags via MusicBrainz, fetches art,
# and MOVES accepted files into /music (same filesystem as staging → atomic
# rename, no copy). Then pokes Jellyfin to rescan so the album is playable
# within the poll interval rather than at the next scheduled scan.
#
# Files beets does NOT consume (true duplicates, unreadable files) are swept
# to /staging/.review for human eyes instead of being retried forever.
#
# Env (set in docker-compose.yml / services/music/.env):
#   JELLYFIN_URL         default http://jellyfin:8096 (coralstack network)
#   JELLYFIN_API_KEY     optional — if unset, refresh is skipped (Jellyfin's
#                        own scheduled scan becomes the surface latency)
#   POLL_SECONDS         default 60
#   QUIESCENCE_SECONDS   default 120
set -euo pipefail

JELLYFIN_URL="${JELLYFIN_URL:-http://jellyfin:8096}"
POLL_SECONDS="${POLL_SECONDS:-60}"
QUIESCENCE_SECONDS="${QUIESCENCE_SECONDS:-120}"
STAGING=/staging
REVIEW="$STAGING/.review"
BEETS_CONFIG=/etc/beets/config.yaml

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

audio_files() {
    find "$STAGING" -path "$REVIEW" -prune -o -type f \
        \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' \
           -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' \
           -o -iname '*.aiff' -o -iname '*.wv' -o -iname '*.ape' \) \
        -print 2>/dev/null
}

recently_modified() {
    # Any file (audio or not — covers art/zips mid-copy) touched within the
    # quiescence window. mmin takes minutes; round up.
    find "$STAGING" -path "$REVIEW" -prune -o -type f \
        -mmin "-$(( (QUIESCENCE_SECONDS + 59) / 60 ))" -print -quit 2>/dev/null
}

trigger_jellyfin() {
    if [[ -z "${JELLYFIN_API_KEY:-}" ]]; then
        log "JELLYFIN_API_KEY not set — skipping refresh (scheduled scan will pick it up)"
        return 0
    fi
    if curl -fsS -X POST "${JELLYFIN_URL}/Library/Refresh?api_key=${JELLYFIN_API_KEY}" \
            -o /dev/null --max-time 30; then
        log "Jellyfin refresh triggered"
    else
        log "WARNING: Jellyfin refresh failed (import succeeded; scheduled scan will pick it up)"
    fi
}

log "music-ingest up: watching $STAGING (poll ${POLL_SECONDS}s, quiescence ${QUIESCENCE_SECONDS}s)"
mkdir -p "$REVIEW"

while true; do
    if [[ -n "$(audio_files | head -1)" ]]; then
        if [[ -n "$(recently_modified)" ]]; then
            log "drop in progress (files still changing) — waiting"
        else
            count=$(audio_files | wc -l | tr -d ' ')
            log "importing $count quiescent audio file(s)…"
            # --quiet: apply strong MusicBrainz matches, no prompts. Weak
            # matches fall back to as-is import (tags from the store are
            # good — Qobuz/Bandcamp files arrive well-tagged). Exit status
            # is non-fatal: leftovers are swept to .review either way.
            beet --config "$BEETS_CONFIG" import --quiet "$STAGING" \
                || log "WARNING: beets exited non-zero"
            # Sweep anything beets left behind (duplicates, non-audio
            # residue like .zip/.pdf booklets, failures) into .review, then
            # prune empty album dirs.
            leftovers=$(find "$STAGING" -path "$REVIEW" -prune -o -type f -print 2>/dev/null)
            if [[ -n "$leftovers" ]]; then
                log "sweeping leftovers to .review:"
                while IFS= read -r f; do
                    log "  $f"
                    dest="$REVIEW/${f#"$STAGING"/}"
                    mkdir -p "$(dirname "$dest")"
                    mv "$f" "$dest"
                done <<< "$leftovers"
            fi
            find "$STAGING" -mindepth 1 -path "$REVIEW" -prune -o -type d -empty -delete 2>/dev/null || true
            trigger_jellyfin
        fi
    fi
    sleep "$POLL_SECONDS"
done
