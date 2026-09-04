# Custom Caddy build with the Cloudflare DNS provider plugin baked in.
# We need this because Let's Encrypt DNS-01 challenges are handled by
# provider-specific modules, and Cloudflare isn't in the upstream Caddy image.
#
# ⚠️ THE TWO CADDY VERSIONS BELOW MUST MATCH, and nothing enforces it.
# Renovate resolves `-builder-alpine` and `-alpine` as separate dependencies,
# so a bump can land them on different versions — it did exactly that in PR #29
# (builder 2.11.3, runtime 2.11.4). The mismatch is INVISIBLE at runtime: the
# binary copied out of the builder overwrites the base image's, so the Caddy
# that actually serves is the BUILDER's version. `caddy version` inside the
# container would have reported 2.11.3 while the image tag said 2.11.4.
# When you review a Caddy bump, check both lines.
FROM caddy:2.11.4-builder-alpine AS builder

# Pin the Cloudflare plugin explicitly. v0.2.4 (2026-03-24) added regex
# support for Cloudflare's account-scoped cfat_/cfut_ tokens. Before that,
# the provisioner rejected these tokens locally before any API call.
# Leaving this unpinned can silently resolve to a cached older build.
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.4-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
