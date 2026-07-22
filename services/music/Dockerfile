# CoralStack music ingest — containerized beets watch-folder.
#
# Custom image (like backup/ and caddy/) so the toolchain is explicit:
#   - beets   : the ingest brain — MusicBrainz tagging, art, dedup, filing
#               into ${STORAGE_PATH}/music
#   - pillow  : lets beets' fetchart/embedart resize and embed cover art
#               without an ImageMagick dependency
#   - requests: fetchart's HTTP client
#   - curl    : fires the Jellyfin library-refresh API call after an import
#
# The container runs a quiescence-aware watch loop (ingest.sh), not cron:
# imports should happen as soon as a drop finishes, not on a schedule.
FROM python:3.14-slim-bookworm

ARG BEETS_VERSION=2.12.0

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir \
      "beets==${BEETS_VERSION}" \
      pillow \
      requests

COPY ingest.sh /usr/local/bin/ingest.sh
RUN chmod +x /usr/local/bin/ingest.sh

# Invoke by absolute path (see the backup-supercronic-PID1 incident: PATH
# assumptions in ENTRYPOINT/CMD are how containers crash-loop).
CMD ["/usr/local/bin/ingest.sh"]
