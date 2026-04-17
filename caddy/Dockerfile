# Custom Caddy build with the Cloudflare DNS provider plugin baked in.
# We need this because Let's Encrypt DNS-01 challenges are handled by
# provider-specific modules, and Cloudflare isn't in the upstream Caddy image.
FROM caddy:2.11.2-builder-alpine AS builder

RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

FROM caddy:2.11.2-alpine

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
