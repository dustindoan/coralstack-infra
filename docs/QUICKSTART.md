# Quickstart

End-to-end first-run walkthrough. Takes ~30 minutes on a fresh host, longer if
you're also migrating existing Immich/Vaultwarden data.

## Prerequisites

- A Linux host (Intel NUC or similar). These instructions target Debian/Ubuntu.
- Docker Engine + Compose v2. Install from [docs.docker.com](https://docs.docker.com/engine/install/).
- External storage mounted somewhere stable (default: `/mnt/storage`).
- Tailscale installed and logged in (optional but recommended for the MVP —
  it's the easiest way to make the box reachable without opening ports).

## 1. Clone and configure

```bash
git clone <this-repo> coralstack-infra
cd coralstack-infra
cp .env.example .env
```

Edit `.env`:

| Variable       | What it is                                     | Example                               |
| -------------- | ---------------------------------------------- | ------------------------------------- |
| `COMMUNITY`    | Short slug identifying this deployment         | `campbellriver`                       |
| `BASE_DOMAIN`  | Root domain; subdomains derived from it        | `campbellriver.coralstack.org`        |
| `TZ`           | Host timezone                                  | `America/Vancouver`                   |
| `STORAGE_PATH` | Where photos/music/etc. live on disk           | `/mnt/storage`                        |
| `DATA_PATH`    | Where container state lives                    | `./data` or `/mnt/storage/coralstack` |
| `ACME_EMAIL`   | Email for Let's Encrypt (leave blank for now)  | (blank)                               |

For Tailscale-only deployments, point `BASE_DOMAIN` at a name you control via
MagicDNS (e.g. `nuc.tailXXXX.ts.net`), or just pick any DNS-looking string and
accept the Caddy-internal cert on each device.

## 2. Prepare the storage layout

```bash
sudo mkdir -p /mnt/storage/{photos,music,movies,tv}
sudo chown -R $USER:$USER /mnt/storage
```

If you're migrating from existing services, move the data into place now:

- **Immich:** the upload directory (usually `UPLOAD_LOCATION` in the old compose)
  becomes `${STORAGE_PATH}/photos`. The Postgres volume moves to
  `${DATA_PATH}/immich/postgres`. Stop the old compose, `rsync -a` the data,
  then continue.
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

- **Caddy cert warnings in the browser:** expected with `tls internal`. Either
  trust the Caddy root CA on each device (`docker compose exec caddy cat /data/caddy/pki/authorities/local/root.crt`)
  or switch to Let's Encrypt once DNS is pointed.
- **`docker compose up` can't find the network:** the `coralstack` network is
  defined in the root compose. Always run `docker compose` commands from the
  repo root, not from a service directory.
- **Immich postgres fails to start after migration:** version mismatch. Check
  the postgres image tag matches what your old data was created with.
