# CoralStack SMART monitor — disk health polling, scheduled by supercronic.
#
# Custom image (like backup/ and ente-janitor/) so the toolchain is explicit:
#   - smartmontools : reads SMART attributes off the physical drives
#   - jq            : parses `smartctl --json` (far more robust than awk over
#                     the human-readable attribute table, whose columns move
#                     between drive models)
#   - curl          : pushes the verdict to the Uptime Kuma push monitor
#   - supercronic   : container-friendly cron that passes the parent env to
#                     jobs (busybox crond strips it — a classic footgun)
#
# Base = alpine rather than one of the app images: this container has no
# relationship to any service's data, and a small base keeps a container that
# needs raw block-device access as boring as possible.
FROM alpine:3.21

# https://github.com/aptible/supercronic/releases
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA1SUM=71b0d58cc53f6bd72cf2f293e09e294b79c666d8

RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      jq \
      smartmontools \
      tzdata \
 && curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA1SUM}  /usr/local/bin/supercronic" | sha1sum -c - \
 && chmod +x /usr/local/bin/supercronic

COPY smart-check.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/smart-check.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron"]
