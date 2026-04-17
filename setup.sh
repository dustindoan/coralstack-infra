#!/usr/bin/env bash
# CoralStack first-run bootstrap.
#
# Idempotent: safe to re-run. Generates per-service secrets if missing,
# creates data directories, and brings the stack up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ─── Pinned upstream versions ────────────────────────────────────────────────
# Bumping Immich is a two-step: change IMMICH_VERSION here, re-run setup.sh.
# It refetches the upstream compose and writes the matching version into
# services/immich/.env.
IMMICH_VERSION=v2.7.5
JELLYFIN_SSO_VERSION=4.0.0.4

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ─── Prereqs ─────────────────────────────────────────────────────────────────
command -v docker >/dev/null || die "docker not found. Install Docker Engine first."
docker compose version >/dev/null 2>&1 || die "docker compose v2 not found."
command -v openssl >/dev/null || die "openssl not found (needed for secret generation)."

# ─── Root .env ───────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
	log "Creating .env from .env.example — edit it before continuing."
	cp .env.example .env
	warn "Set COMMUNITY, BASE_DOMAIN, STORAGE_PATH in .env, then re-run ./setup.sh"
	exit 0
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

: "${BASE_DOMAIN:?BASE_DOMAIN is not set in .env}"
: "${STORAGE_PATH:?STORAGE_PATH is not set in .env}"
: "${ACME_EMAIL:?ACME_EMAIL is not set in .env (required for Lets Encrypt)}"
: "${CF_API_TOKEN:?CF_API_TOKEN is not set in .env (required for Cloudflare DNS-01 ACME)}"
: "${DATA_PATH:=./data}"

# Absolute version of DATA_PATH — Immich's compose bind-mounts are relative
# to the included compose file's directory, so we need absolute paths for
# the vars we inject into services/immich/.env.
if [[ "$DATA_PATH" = /* ]]; then
	ABS_DATA_PATH="$DATA_PATH"
else
	ABS_DATA_PATH="$REPO_ROOT/${DATA_PATH#./}"
fi

[[ -d "$STORAGE_PATH" ]] || warn "STORAGE_PATH ($STORAGE_PATH) doesn't exist yet — create it before starting services that need it."

# ─── Data dirs ───────────────────────────────────────────────────────────────
log "Creating data directories under $DATA_PATH"
mkdir -p \
	"$DATA_PATH/caddy/data" "$DATA_PATH/caddy/config" \
	"$DATA_PATH/pocket-id" \
	"$DATA_PATH/vaultwarden" \
	"$DATA_PATH/jellyfin/config" "$DATA_PATH/jellyfin/cache" \
	"$DATA_PATH/immich/model-cache" "$DATA_PATH/immich/postgres"

# ─── Per-service secrets ─────────────────────────────────────────────────────
# Copy .env.example → .env for any service that doesn't have one yet, then
# fill in blank secrets. Each service's secret generation is opt-in below.

init_service_env() {
	local svc="$1"
	local path="services/$svc/.env"
	local example="services/$svc/.env.example"
	[[ -f "$example" ]] || return 0
	if [[ ! -f "$path" ]]; then
		log "Initializing services/$svc/.env"
		cp "$example" "$path"
	fi
}

# Fill a blank KEY= line in a file with a generated value. No-op if already set.
fill_secret() {
	local file="$1" key="$2" value="$3"
	if grep -qE "^${key}=$" "$file"; then
		# Use a temp file to avoid sed portability issues between GNU/BSD.
		awk -v k="$key" -v v="$value" '
			$0 ~ "^" k "=$" { print k "=" v; next }
			{ print }
		' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
		log "Generated $key in $file"
	fi
}

# Unconditionally set KEY=value in a file (used for paths derived from root
# .env, which should always stay in sync). Creates the line if missing.
set_value() {
	local file="$1" key="$2" value="$3"
	if grep -qE "^${key}=" "$file"; then
		awk -v k="$key" -v v="$value" '
			$0 ~ "^" k "=" { print k "=" v; next }
			{ print }
		' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
	else
		echo "${key}=${value}" >> "$file"
	fi
}

gen_hex()    { openssl rand -hex 32; }
gen_base64() { openssl rand -base64 48 | tr -d '\n'; }

init_service_env pocket-id
init_service_env vaultwarden
init_service_env immich

fill_secret services/pocket-id/.env   ENCRYPTION_KEY   "$(gen_hex)"
fill_secret services/vaultwarden/.env ADMIN_TOKEN      "$(gen_base64)"

# Immich: only DB_PASSWORD is needed — upstream's postgres service reads it
# directly from the shared .env. Paths are derived from root config so they
# track DATA_PATH/STORAGE_PATH edits.
# All fill-if-blank so migrating from an existing Immich install is just:
#   cp /path/to/old/immich/.env services/immich/.env
# setup.sh then fills whatever's still blank without touching existing values.
fill_secret services/immich/.env      DB_PASSWORD      "$(gen_hex)"
fill_secret services/immich/.env      IMMICH_VERSION   "$IMMICH_VERSION"
fill_secret services/immich/.env      UPLOAD_LOCATION  "$STORAGE_PATH/photos"
fill_secret services/immich/.env      DB_DATA_LOCATION "$ABS_DATA_PATH/immich/postgres"

# ─── Immich upstream compose ─────────────────────────────────────────────────
# Fetch the pinned release's docker-compose.yml so our overlay can include it
# verbatim. This gives us automatic version alignment (postgres, Valkey, ML,
# server) without hand-copying upstream's pins.
immich_upstream=services/immich/upstream.yml
if [[ ! -f "$immich_upstream" ]]; then
	log "Fetching Immich $IMMICH_VERSION upstream compose"
	command -v curl >/dev/null || die "curl not found (needed to fetch Immich upstream compose)."
	curl -fsSL \
		"https://github.com/immich-app/immich/releases/download/$IMMICH_VERSION/docker-compose.yml" \
		-o "$immich_upstream"
	log "Fetched $immich_upstream — delete it to re-fetch on next run (e.g. after bumping IMMICH_VERSION)."
fi

# ─── Jellyfin SSO plugin (pre-seed) ──────────────────────────────────────────
# Drop the SSO plugin into the Jellyfin config volume so it's loaded on first
# boot. No admin-UI install required. Skip if already present or if Jellyfin
# is commented out of the top-level compose.
jellyfin_plugin_dir="$DATA_PATH/jellyfin/config/plugins/SSO-Auth_${JELLYFIN_SSO_VERSION}"

if grep -qE '^\s*-\s*services/jellyfin/' docker-compose.yml && [[ ! -d "$jellyfin_plugin_dir" ]]; then
	log "Installing jellyfin-plugin-sso v${JELLYFIN_SSO_VERSION}"
	command -v curl >/dev/null || die "curl not found (needed for Jellyfin plugin install)."
	command -v unzip >/dev/null || die "unzip not found (needed for Jellyfin plugin install)."
	tmp_zip="$(mktemp -t jellyfin-sso.XXXXXX).zip"
	curl -fsSL \
		"https://github.com/9p4/jellyfin-plugin-sso/releases/download/v${JELLYFIN_SSO_VERSION}/sso-authentication_${JELLYFIN_SSO_VERSION}.zip" \
		-o "$tmp_zip"
	mkdir -p "$jellyfin_plugin_dir"
	unzip -q -o "$tmp_zip" -d "$jellyfin_plugin_dir"
	rm -f "$tmp_zip"
	log "Plugin staged at $jellyfin_plugin_dir"
fi

# ─── Bring it up ─────────────────────────────────────────────────────────────
log "Pulling images (this may take a while on first run)…"
docker compose pull

log "Starting the stack"
docker compose up -d

log "Stack is up. Check status with: docker compose ps"
echo
cat <<EOF
Next steps:

  1. Watch Caddy obtain certs: docker compose logs -f caddy
     (First boot takes 30-60s for DNS-01 challenges + LE issuance.)

  2. Open https://id.${BASE_DOMAIN} and create the first Pocket ID admin user.

  3. Wire OIDC into Immich and Jellyfin - see docs/ONBOARDING.md.
EOF
