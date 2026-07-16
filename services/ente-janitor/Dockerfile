# CoralStack Ente janitor — bounds Ente's deletion-queue disk window.
#
# Custom image (like backup/) so the toolchain is explicit and auditable:
#   - psql        : runs the queue-backdate + stats SQL against ente-postgres
#   - supercronic : container-friendly cron that passes the parent env to jobs
#
# Base = postgres:15-alpine so the psql client is version-matched to
# ente-postgres:15, same rationale as services/backup. Bump in lockstep with
# the Ente Postgres image version.
FROM postgres:15-alpine

# https://github.com/aptible/supercronic/releases
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA1SUM=71b0d58cc53f6bd72cf2f293e09e294b79c666d8

RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      tzdata \
 && curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA1SUM}  /usr/local/bin/supercronic" | sha1sum -c - \
 && chmod +x /usr/local/bin/supercronic

COPY janitor.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/janitor.sh /usr/local/bin/entrypoint.sh

# The postgres base image sets ENTRYPOINT/CMD for running a database; override
# both so the container runs our scheduler instead.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron"]
