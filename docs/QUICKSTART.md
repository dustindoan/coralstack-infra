# Quickstart

End-to-end first-run walkthrough. Takes ~30 minutes on a fresh host, longer if
you're also migrating existing Immich/Vaultwarden data.

## Prerequisites

- A Linux host (Intel NUC or similar). These instructions target Debian/Ubuntu.
- Docker Engine + Compose v2. Install from [docs.docker.com](https://docs.docker.com/engine/install/).
- External storage mounted somewhere stable (default: `/mnt/storage`).
- Tailscale installed and logged in. The NUC stays off the public internet;
  members join your tailnet to reach it.
- A domain with DNS hosted at **Cloudflare**. The domain can be registered
  anywhere (Hostinger, Namecheap, etc.) — only the DNS nameservers need to
  point at Cloudflare. See [DNS setup](#dns-setup) below.

## DNS setup

Caddy obtains real Let's Encrypt certs via the Cloudflare DNS-01 challenge,
so the NUC never needs to be reachable from the public internet.

1. At **Cloudflare**: add your domain to a free account. It hands you two
   nameservers. Switch your registrar to use them.
2. Create a **DNS A record**: `*.<community>.<domain>` → your NUC's tailnet
   IP (`tailscale ip -4`). Set **Proxy status: DNS only** (grey cloud). The
   record is public but the IP is only routable over the tailnet.
3. Create a **scoped API token** at
   [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens):
   Permissions `Zone → DNS → Edit`, scoped to this zone. Copy it.

## 1. Clone and configure

```bash
git clone <this-repo> coralstack-infra
cd coralstack-infra
cp .env.example .env
```

Edit `.env`:

| Variable        | What it is                                     | Example                               |
| --------------- | ---------------------------------------------- | ------------------------------------- |
| `COMMUNITY`     | Short slug identifying this deployment         | `campbellriver`                       |
| `BASE_DOMAIN`   | Root domain; subdomains derived from it        | `campbellriver.coralstack.org`        |
| `TZ`            | Host timezone                                  | `America/Vancouver`                   |
| `STORAGE_PATH`  | Where photos/music/etc. live on disk           | `/mnt/storage`                        |
| `DATA_PATH`     | Where container state lives                    | `./data` or `/mnt/storage/coralstack` |
| `ACME_EMAIL`    | Email for Let's Encrypt expiry notifications   | `you@example.com`                     |
| `CF_API_TOKEN`  | Cloudflare API token from the step above       | `xyz…`                                |

## 2. Prepare the storage layout

```bash
sudo mkdir -p /mnt/storage/{photos,music,movies,tv}
sudo chown -R $USER:$USER /mnt/storage
```

If you're migrating from existing services, move the data into place now:

- **Immich:** easiest — our compose includes Immich's upstream `docker-compose.yml`
  verbatim, so if you're already on a recent Immich release you can keep the
  existing data in place. Stop your old compose (`cd /path/to/old/immich && docker compose down`),
  then `cp /path/to/old/immich/.env services/immich/.env`. Set `IMMICH_VERSION`
  in that file to match the `IMMICH_VERSION` constant at the top of `setup.sh`
  (bump `setup.sh` up if needed). Your `UPLOAD_LOCATION` and `DB_DATA_LOCATION`
  can stay pointing at their current absolute paths — our compose reads them
  verbatim from your copied `.env`. setup.sh won't overwrite an existing
  `services/immich/.env`, so nothing gets regenerated.
- **Navidrome → Jellyfin:** the library directory is unchanged — both read
  from `${STORAGE_PATH}/music`. Jellyfin will rescan on first boot.
- **Vaultwarden:** in alpha, assume a fresh start. If you want to preserve
  the existing `/data` volume, stop the old container and copy it to
  `${DATA_PATH}/vaultwarden` before running setup.

## 3. Pick your services

Edit `docker-compose.yml` and comment out any service under `include:` that
you don't want. Pocket ID should stay enabled — everything else points to it
for SSO.

## 4. Run setup

```bash
./setup.sh
```

It will:
1. Create `.env` files for each service and fill in generated secrets.
2. Create data directories under `${DATA_PATH}`.
3. Pull images and `docker compose up -d`.

Re-running `setup.sh` is safe — it only fills in missing secrets.

## 5. First login

- **Pocket ID:** `https://id.${BASE_DOMAIN}` — create the first admin user.
  This account becomes the passkey root for the community.
- **Immich:** `https://photos.${BASE_DOMAIN}` — create the admin account
  locally first; you'll wire OIDC after.
- **Jellyfin:** `https://media.${BASE_DOMAIN}` — complete the setup wizard,
  point it at `/media/music`.
- **Vaultwarden:** `https://vault.${BASE_DOMAIN}` — flip `SIGNUPS_ALLOWED=true`
  in `services/vaultwarden/.env`, restart (`docker compose restart vaultwarden`),
  create your account, then flip it back to `false`.

## 6. Wire up SSO

See [ONBOARDING.md](ONBOARDING.md) for OIDC client setup in Pocket ID and the
matching config in Immich / Jellyfin.

## Troubleshooting

- **Caddy fails to get certs:** check `docker compose logs caddy`. Common
  causes: token lacks `Zone:DNS:Edit` on the right zone; DNS nameserver
  switch hasn't propagated yet (`dig NS coralstack.org` should return
  Cloudflare's nameservers); rate-limited by Let's Encrypt after repeated
  failures (wait an hour and retry).
- **Browser can reach Caddy but service gives 502:** the upstream container
  isn't running. `docker compose ps` and check the service's logs.
- **`docker compose up` can't find the network:** the `coralstack` network is
  defined in the root compose. Always run `docker compose` commands from the
  repo root, not from a service directory.
- **Immich postgres fails to start after migration:** version mismatch between
  the upstream compose we fetched and your existing data. Check
  `services/immich/upstream.yml` postgres tag against what your old compose
  used; if they differ, either adjust `IMMICH_VERSION` in `setup.sh` to match
  your data's era, or follow Immich's upgrade path to migrate the DB forward.
