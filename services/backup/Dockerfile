# CoralStack backups — restic + rclone, scheduled by supercronic.
#
# Custom image (like our Caddy) so the toolchain is explicit and auditable:
#   - restic   : encrypted, deduplicated, vendor-neutral backup repo format
#   - rclone   : lets restic target ~any provider (B2/Wasabi/R2/SFTP/MinIO/a
#                co-op member's box) purely from env vars — no vendor lock-in
#   - pg_dump  : ships in the base image, version-matched to ente-postgres:15
#   - sqlite   : online .backup of Vaultwarden + Pocket ID databases
#   - supercronic : container-friendly cron that passes the parent env to jobs
#                   (busybox crond strips the environment — a classic footgun)
#
# Base = postgres:15-alpine specifically so pg_dump/pg_restore match the
# ente-postgres:15 server exactly (no cross-version restore surprises). It's
# Alpine-based, so restic/rclone/sqlite come from apk. Bump in lockstep with
# the Ente Postgres image version.
FROM postgres:15-alpine

# https://github.com/aptible/supercronic/releases
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA1SUM=71b0d58cc53f6bd72cf2f293e09e294b79c666d8

RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      restic \
      rclone \
      sqlite \
      tzdata \
 && curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA1SUM}  /usr/local/bin/supercronic" | sha1sum -c - \
 && chmod +x /usr/local/bin/supercronic

COPY backup.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

# The postgres base image sets ENTRYPOINT/CMD for running a database; override
# both so the container runs our scheduler (as root, to read the data mounts).
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron"]
