# Matrix — chat as a CoralStack service

> **Status (2026-09-03):** 🚧 declared, **not deployed**. Every file below is in
> the repo; nothing is running on the box. Deploying creates **three new public
> vhosts**, so read [First deploy](#first-deploy-read-this-before-composing-up)
> before `docker compose up`.

## Why this is here

It started as plumbing for the admin agent — the agent needs a channel to talk
to, and the alternative was Signal, which cannot be self-hosted. Following that
thread produced a better answer: **the channel should be a service the co-op
runs, and the agent is then just one of its users.**

Matrix is the only mainstream messaging protocol that is genuinely federated.
You run a homeserver; it interoperates with every other homeserver by DNS, with
no central registry and nobody to sign up with — the same shape as email. For a
project whose whole pitch is *the cloud, brought home*, a chat service you host
that federates with peer communities is about as on-message as the stack gets.

The decisive part is the multi-co-op fit. `BASE_DOMAIN` is already
`campbellriver.coralstack.org` — community-scoped, not service-scoped. So:

```
@dustin:campbellriver.coralstack.org        ← this co-op
@someone:othercoop.coralstack.org           ← a sibling, federating as a peer
#general:campbellriver.coralstack.org       ← a room replicated across both
```

That is the Phase 3 network-of-communities shape falling out of the protocol
for free, and it matches the topology decision already made elsewhere: a sibling
site is a peer that plays a role, not a rental.

## Three decisions, made deliberately

### 1. `server_name` is the bare community domain

`server_name: campbellriver.coralstack.org`, **not** `chat.…`.

This is permanent in a way little else in the stack is. It's baked into every
user ID and into every room the server has ever joined; changing it doesn't
migrate anything, it creates a different server. The bare domain gives IDs that
read as a community rather than a service endpoint, and makes sibling co-ops
peers rather than subdomains of one another.

The cost is one indirection: Synapse runs at `matrix.${BASE_DOMAIN}`, and the
**apex serves `/.well-known/matrix/server`** telling the network where to
actually connect. That delegation is why this needs no port 8448 and rides the
existing single 443 forward — it fits the box-as-LAN-peer topology instead of
fighting it.

### 2. Federation is an allowlist, starting empty

`federation_domain_whitelist: []` in `homeserver.yaml.template`.

The architecture is correct from day one — right `server_name`, working
delegation — but no unknown server can reach this one. Nothing is lost: **no
sibling co-op exists yet.** Adding the first peer is one line and no migration.

> Note the sharp edge: *lengthening* the list adds peers, but **deleting the key
> entirely** turns on open federation with the whole Matrix network. Those look
> similar in a diff and are not.

### 3. Synapse + MAS, not Synapse alone

Login is handled by **Matrix Authentication Service**, not Synapse. The chain is
one hop longer than everything else in the stack:

```
Element  →  MAS  →  Pocket ID
            (issues Matrix tokens)  (says who you are)
```

Why accept the extra service: there is no supported way to wire Synapse straight
to an external OIDC provider *and* keep Element X on mobile working — Element X
mandates MAS. It is also the path matrix.org itself migrated to. The cost is
three containers plus a dedicated Postgres.

**The Postgres is dedicated on purpose.** Synapse requires its database be
created with `C` collation; getting that wrong corrupts search ordering and is
only fixable by dump/restore. Rather than impose that on the instance Ente also
uses, Matrix gets its own, holding two databases (`synapse`, `mas`).

## Shape

| Piece | Image | Vhost |
| --- | --- | --- |
| Synapse | `ghcr.io/element-hq/synapse:v1.159.0` | `matrix.${BASE_DOMAIN}` |
| MAS | `ghcr.io/element-hq/matrix-authentication-service:1.23.0` | `auth.${BASE_DOMAIN}` |
| Element | `ghcr.io/element-hq/element-web:v1.12.26` | `chat.${BASE_DOMAIN}` |
| Postgres | `postgres:15` | internal |
| delegation | — | apex `${BASE_DOMAIN}` |

> **MAS tags carry no leading `v`** (`1.23.0`) while Synapse and Element do
> (`v1.159.0`). `renovate.json` has an explicit rule for this; without it
> Renovate misreads the scheme and goes quiet.

> **Use the stable config section, not the tutorials.** Synapse now takes a
> top-level `matrix_authentication_service:` block (`enabled` / `endpoint` /
> `secret`). Most guides still show `experimental_features.msc3861:` with an
> issuer, client_id, client_secret and admin_token — that form is superseded and
> the current docs say to remove it. The whole handshake is now one shared
> secret. `homeserver.yaml.template` uses the stable form.

### Two things that break silently

Three paths **must** reach MAS rather than Synapse, and the Caddy block for them
has to precede the catch-all `reverse_proxy`:

```
/_matrix/client/*/login
/_matrix/client/*/logout
/_matrix/client/*/refresh
```

Synapse has delegated login and will not answer these. Get it wrong and the
symptom is "login doesn't work" with nothing obviously broken in either
container's log — the worst kind of failure to debug after the fact.

**Second: the Matrix Postgres password must be URI-safe.** MAS takes its
database as a `uri`, so a base64 password containing `@`, `/` or `+` corrupts
the connection string without a clear error. `setup.sh` generates hex here and
base64 everywhere else in the stack for exactly this reason.

The apex `/.well-known/matrix/client` must also advertise the
`org.matrix.msc2965.authentication` block, or clients try the legacy password
flow, which is disabled, and fail unhelpfully. Both need
`Access-Control-Allow-Origin: *` — they're fetched cross-origin from the browser.

## First deploy — read this before composing up

**This creates three public vhosts at once**, and this stack has already been
bitten by a first-run claim window: Uptime Kuma's setup wizard sat publicly
reachable and unclaimed (docs/SECURITY_PASS.md, SEC-2). The mitigations here are
built into the config rather than left to a race:

- `passwords.enabled: false` and `password_registration_enabled: false` in MAS —
  no local accounts exist to claim, ever.
- `enable_registration: false` in Synapse as defence in depth, so a misconfigured
  delegation fails to "nobody can log in" rather than "open registration".
- Until `MATRIX_OIDC_CLIENT_*` are set, MAS has **no identity provider at all**
  and nobody can sign in. That is the intended state on first boot, not a bug —
  `setup.sh` warns rather than papering over it.

### Pre-flight — four things learned after this branch was written

The 2026-09-04 session deployed unrelated changes and hit three of these. They
are cheap before you start and annoying to discover at step 4.

1. **Validate the Caddyfile first.** There is no `caddy` binary on the
   workstation, so the three MAS compat paths in this branch have never been
   parsed by Caddy. Get it onto the box and run
   `docker exec caddy caddy validate --config /etc/caddy/Caddyfile` **before**
   composing anything up. The failure mode if they're wrong is "login doesn't
   work" with clean logs on both sides — expensive to debug, seconds to rule out.
2. **Adding vhosts means editing two places.** Caddy carries every vhost as a
   docker network alias in the root `docker-compose.yml`, separately from the
   Caddyfile. `chat.`, `auth.` and `matrix.` need adding there too, or
   inter-service calls hairpin out through the eero instead of resolving
   internally.
3. **A Caddy recreation pages you.** Deploying this restarts Caddy, which gives
   it a new container IP; a long-running Uptime Kuma keeps using the old one and
   the edge monitor goes DOWN without self-healing. Finish the deploy with
   `docker compose restart uptime-kuma` then `docker compose restart autokuma`
   (the second is mandatory). Details and the measured evidence are in
   [MONITORING.md](MONITORING.md).
4. **This branch's two monitors will land unalerted.** AutoKuma creates monitors
   with no notification attached — Kuma's "Default enabled" does not reach them
   (measured 2026-09-04). After deploy, attach the channel in Kuma: edit the
   ntfy notification and tick **Apply on all existing monitors**. Until then
   `Matrix (Synapse)` and `Matrix (MAS)` are green squares nobody is paged about.

Order:

1. `./setup.sh` — generates secrets, the MAS signing key, and Synapse's
   federation signing key, then renders the configs.
2. Create an OIDC client in Pocket ID. Redirect URI:
   `https://auth.${BASE_DOMAIN}/upstream/callback/${MATRIX_OIDC_PROVIDER_ID}`
   (the ULID is in `services/matrix/.env` and must match exactly).
3. Fill `MATRIX_OIDC_CLIENT_ID` / `_SECRET`, re-run `./setup.sh`.
4. `docker compose up -d matrix-db matrix-auth synapse element`
5. Sign in at `https://chat.${BASE_DOMAIN}`.
6. Restart `uptime-kuma` then `autokuma`, and attach the notification channel to
   the two new monitors (pre-flight items 3 and 4).

> **Guard the signing key.** `${DATA_PATH}/matrix/synapse/${BASE_DOMAIN}.signing.key`
> *is* this server's identity to the network. Lose it and peers treat a restored
> server as an impostor and rooms break. It lives under `DATA_PATH`, so it's in
> scope for [BACKUPS.md](BACKUPS.md) — confirm it's actually captured before
> federation is ever enabled.

## What is deliberately not here

- **No bridges.** A Signal or WhatsApp bridge would let members keep their
  existing app, and is the obvious next want. It also means a component holding
  a linked-device credential for someone's personal account. Worth doing later,
  as its own decision.
- **No agent yet.** The agent is a *user* of this service, not part of it. See
  the admin-agent design note; nothing here assumes it exists.
- **Federation is off.** Deliberately. See above.

## Open

- **Synapse is memory-hungry** and the NUC already runs the full stack. Watch it
  after deploy; `caches.global_factor` is the first dial. Tuwunel (the conduwuit
  successor, Rust, far lighter) was the road not taken and stays a fallback if
  Synapse proves too heavy.
- **Backups** — the Matrix Postgres and the signing key need to be in the backup
  set. Verify rather than assume.
- **Is chat a member-facing service or an admin one?** Members would need
  Element and an explanation, on top of an onboarding that is already 2–3 hours.
  Reasonable to run it admin-only first and offer it to members once it has
  proven itself.

## Relationship to other docs

- The admin-agent design note — why this started; the agent becomes a user here.
- [ONBOARDING.md](ONBOARDING.md) — members need an Element walkthrough if chat
  is offered to them.
- [BACKUPS.md](BACKUPS.md) — signing key and Postgres.
- [MONITORING.md](MONITORING.md) — two monitors ship with this
  (`matrix-synapse`, `matrix-auth`); the second exists because Synapse stays
  healthy while login is entirely broken.
