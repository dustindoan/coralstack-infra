# Declared OIDC clients

One file per client. `setup.sh` reconciles these against Pocket ID's REST API on
every run: create what is missing, wire the credentials into the consuming
service's `.env`, and leave anything already wired alone.

## Why this is a shell function and not a container

The AutoKuma comparison is tempting and wrong. Kuma's write path is socket.io
only and stateful, so reconciling it needs a long-running client — hence a
container reading `services/autokuma/monitors/`. Pocket ID has a plain REST API
whose primitives are already idempotent, and crucially it lets the CALLER choose
both the client id and the client secret:

- `POST /api/oidc/clients` takes an optional `id` (2–128 chars)
- `POST /api/oidc/clients/{id}/secrets` takes an optional `secret` (≥16 chars)

So nothing has to be captured from a one-time response and nothing has to be
read back — which is the whole reason this fits in `setup.sh` next to
`fill_secret` instead of needing a new runtime, a state file, or Terraform.

Prior art worth knowing: `ogglord/pocket-id-nixos` does exactly this shape
against the same API, in Nix. Upstream issue #1574 and PR #1619 are adding
native declarative secrets, at which point some of this gets simpler.

## CLIENT_ID is the real id, not a friendly name

The first three clients were created by hand in the admin UI, so Pocket ID
generated UUIDs for them, and the services' `.env` files point at those UUIDs.
Declaring friendly ids like `coralstack-jellyfin` would create DUPLICATE
clients beside the real ones while every service kept using the old UUID. So
existing clients are declared with the id they actually have, read out of
Pocket ID's database on 2026-10-15. New clients may use a readable id.

## What this does not manage

Group membership. All three existing clients have `isGroupRestricted = true`,
which this preserves, but which groups are allowed is set separately via
`PUT /api/oidc/clients/{id}/allowed-user-groups` and is left to the admin UI
for now. Users and groups are a second concern; this file is about clients.
