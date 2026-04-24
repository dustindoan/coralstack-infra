# Quickstart

End-to-end first-run walkthrough. Takes ~30 minutes on a fresh host, longer if
you're also migrating existing Ente/Vaultwarden data or exporting from Immich.

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
2. Create a **wildcard DNS A record**: `*.<community>.<domain>` → your host's
   reachable IP (tailnet IP if Tailscale-only, or your home public IP via
   OPNsense DDNS for the Phase 1 Proxmox setup). Set **Proxy status: DNS only**
   (grey cloud). The wildcard covers every subdomain Caddy serves, including
   the multiple Ente subdomains (`photos.`, `photos-api.`, `photos-accounts.`,
   `photos-albums.`) — no per-subdomain records needed.
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

- **Immich → Ente:** there is no in-place migration path between the two
  (different storage formats, different on-server crypto). If you're moving
  from a previous Immich install, treat your photos as an export-then-reimport:
  use Immich's CLI (`immich upload`) or web UI to download everything to a
  staging folder, then upload to Ente fresh from the mobile app or
  `ente-cli`. Coralstack's design no longer hosts Immich, so the old service
  needs to be torn down separately on the source host before this one comes up.
- **Existing Ente self-host migration:** copy your old `services/ente/.env`
  in (`cp /path/to/old/ente/.env services/ente/.env`) before running
  `setup.sh` — it leaves existing values untouched. Your `${DATA_PATH}/ente/
  postgres` and `${STORAGE_PATH}/ente-minio` directories should be moved into
  place at the same paths the new compose expects.
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
- **Ente Photos:** `https://photos.${BASE_DOMAIN}` — sign up with email +
  Diceware password (save it to your Pocket-ID-SSO'd Vaultwarden). The
  email-verification OTT prints to museum's logs unless SMTP is configured —
  pull it with `docker compose logs ente-museum | grep -i ott`. After signup,
  lock down registration so the world can't create accounts at your URL:
  ```bash
  # find your user ID
  docker compose exec ente-postgres psql -U ente -d ente_db -c \
    "SELECT user_id, email FROM users;"
  # then edit ${DATA_PATH}/ente/museum.yaml: set internal.admin: <your id>
  # and internal.disable-registration: true, then restart museum.
  docker compose restart ente-museum
  ```
  See [ONBOARDING.md](ONBOARDING.md#ente-photos) for the per-member walkthrough.
- **Jellyfin:** `https://media.${BASE_DOMAIN}` — complete the setup wizard,
  point it at `/media/music`.
- **Vaultwarden:** `https://vault.${BASE_DOMAIN}` — flip `SIGNUPS_ALLOWED=true`
  in `services/vaultwarden/.env`, restart (`docker compose restart vaultwarden`),
  create your account, then flip it back to `false`.

## 6. Wire up SSO

See [ONBOARDING.md](ONBOARDING.md) for OIDC client setup in Pocket ID and the
matching config in Vaultwarden / Jellyfin. Ente onboarding is separate (no OIDC
support upstream — see ONBOARDING.md section 3).

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
- **Ente museum exits with `unable to load config`:** check
  `${DATA_PATH}/ente/museum.yaml` exists and is valid YAML. If you edited the
  template (`services/ente/museum.yaml.template`) but the rendered file is
  stale, delete the rendered file and re-run `setup.sh` to re-render.
- **Ente uploads fail with S3 errors:** the socat sidecar isn't routing
  museum→MinIO traffic. `docker compose logs ente-socat` should show the bridge
  is alive; `docker compose logs ente-minio` should show the three buckets
  (`b2-eu-cen`, `wasabi-eu-central-2-v3`, `scw-eu-fr-v3`) created on first run.
  If the buckets are missing, the post_start hook didn't run — restart
  `ente-minio` to retry.
- **Ente OTT email not arriving:** unless you've configured SMTP in
  `museum.yaml`, verification codes go to the museum container's stdout. Pull
  them with `docker compose logs ente-museum | grep -i ott`. Documented as a
  trial-phase compromise — an OIDC-provisioning patch (path A) is queued as
  a deferred followup to eliminate this loop.
