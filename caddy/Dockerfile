# Custom Caddy build with the Cloudflare DNS provider plugin baked in.
# We need this because Let's Encrypt DNS-01 challenges are handled by
# provider-specific modules, and Cloudflare isn't in the upstream Caddy image.
FROM caddy:2.11.2-builder-alpine AS builder

# Pin the Cloudflare plugin explicitly. v0.2.4 (2026-03-24) added regex
# support for Cloudflare's account-scoped cfat_/cfut_ tokens. Before that,
# the provisioner rejected these tokens locally before any API call.
# Leaving this unpinned can silently resolve to a cached older build.
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare@v0.2.4

FROM caddy:2.11.2-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
