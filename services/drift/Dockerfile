# CoralStack deploy-drift monitor — is the box running what the repo says?
#
# Custom image (like backup/, smart/ and ente-janitor/) so the toolchain is
# explicit:
#   - git         : reads local repo state and asks origin one question
#   - sqlite      : counts the monitors Kuma actually has, to compare against
#                   what the repo declares (read-only; the DB is mounted :ro)
#   - curl        : pushes the verdict to the Uptime Kuma push monitor
#   - supercronic : container-friendly cron that passes the parent env to jobs
#                   (busybox crond strips it — a classic footgun)
#
# Base = alpine: this container has no relationship to any service's data. It
# mounts the deploy checkout READ-ONLY and holds no credentials — `git
# ls-remote` against a public repo is anonymous.
FROM alpine:3.24

# https://github.com/aptible/supercronic/releases
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA1SUM=71b0d58cc53f6bd72cf2f293e09e294b79c666d8

RUN apk add --no-cache \
      bash \
      ca-certificates \
      curl \
      git \
      sqlite \
      tzdata \
 && curl -fsSL -o /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
 && echo "${SUPERCRONIC_SHA1SUM}  /usr/local/bin/supercronic" | sha1sum -c - \
 && chmod +x /usr/local/bin/supercronic

COPY drift-check.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/drift-check.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["cron"]
