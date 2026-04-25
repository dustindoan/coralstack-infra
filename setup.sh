#!/usr/bin/env bash
# CoralStack first-run bootstrap.
#
# Idempotent: safe to re-run. Generates per-service secrets if missing,
# creates data directories, and brings the stack up.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ─── Pinned upstream versions ────────────────────────────────────────────────
# Ente image tags live in services/ente/.env (ENTE_SERVER_VERSION,
# ENTE_WEB_VERSION) — bump them there, then docker compose pull && up -d.
JELLYFIN_SSO_VERSION=4.0.0.4

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ─── Prereqs ─────────────────────────────────────────────────────────────────
# Auto-install missing userland tools on Debian/Ubuntu. Docker itself is out of
# scope — too many install paths (get.docker.com, distro repo, Docker Desktop).
ensure_pkg() {
	local cmd="$1" pkg="${2:-$1}"
	command -v "$cmd" >/dev/null && return 0
	if command -v apt-get >/dev/null; then
		log "Installing $pkg (provides $cmd)"
		sudo apt-get update -qq
		sudo apt-get install -y "$pkg"
	else
		die "$cmd not found, and no apt-get available. Install $pkg manually."
	fi
}

ensure_pkg curl
ensure_pkg unzip
ensure_pkg openssl
# envsubst (used to render services/ente/museum.yaml from its template) ships
# in gettext-base on Debian/Ubuntu, gettext on Fedora/Arch.
ensure_pkg envsubst gettext-base

command -v docker >/dev/null || die "docker not found. Install Docker Engine first: curl -fsSL https://get.docker.com | sudo sh"
docker compose version >/dev/null 2>&1 || die "docker compose v2 not found (bundled with modern Docker Engine)."

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

# Resolve DATA_PATH to absolute so every compose file (root + included) gets
# the same mount paths. Docker compose's `include:` resolves relative paths
# relative to the INCLUDED file's directory, not the project root — so a
# DATA_PATH of "./data" means different dirs in root vs service compose
# files. Absolute paths sidestep the ambiguity entirely.
if [[ "$DATA_PATH" != /* ]]; then
	ABS_DATA_PATH="$REPO_ROOT/${DATA_PATH#./}"
	# Normalize to a real path (handles .., symlinks, double slashes)
	mkdir -p "$ABS_DATA_PATH"
	ABS_DATA_PATH="$(cd "$ABS_DATA_PATH" && pwd)"
	log "Resolved DATA_PATH → $ABS_DATA_PATH (was: $DATA_PATH)"
	# Write the absolute path back to .env so future setup.sh runs AND
	# `docker compose` invocations both see the same resolved value.
	if grep -q '^DATA_PATH=' .env; then
		sed -i.bak "s|^DATA_PATH=.*|DATA_PATH=$ABS_DATA_PATH|" .env && rm -f .env.bak
	else
		printf '\nDATA_PATH=%s\n' "$ABS_DATA_PATH" >> .env
	fi
	DATA_PATH="$ABS_DATA_PATH"
else
	ABS_DATA_PATH="$DATA_PATH"
fi

[[ -d "$STORAGE_PATH" ]] || warn "STORAGE_PATH ($STORAGE_PATH) doesn't exist yet — create it before starting services that need it."

# ─── Data dirs ───────────────────────────────────────────────────────────────
log "Creating data directories under $DATA_PATH"
mkdir -p \
	"$DATA_PATH/caddy/data" "$DATA_PATH/caddy/config" \
	"$DATA_PATH/pocket-id" \
	"$DATA_PATH/vaultwarden" \
	"$DATA_PATH/jellyfin/config" "$DATA_PATH/jellyfin/cache" \
	"$DATA_PATH/ente/postgres" "$DATA_PATH/ente/museum-data"

# Ente photo blobs land on STORAGE_PATH (USB-attached storage), not DATA_PATH
# (root FS). Pre-create the bucket dir if STORAGE_PATH is mounted; if it isn't,
# the compose's ${STORAGE_PATH:?...} guard will fail fast with a clear error.
if [[ -d "$STORAGE_PATH" ]]; then
	mkdir -p "$STORAGE_PATH/ente-minio"
fi

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
init_service_env ente

fill_secret services/pocket-id/.env   ENCRYPTION_KEY   "$(gen_hex)"
fill_secret services/vaultwarden/.env ADMIN_TOKEN      "$(gen_base64)"

# Ente secrets — sized to match what museum's libsodium APIs decode to
# (crypto_secretbox_KEYBYTES=32 for ENTE_MUSEUM_KEY, generichash_BYTES_MAX=64
# for ENTE_MUSEUM_HASH). Don't change these sizes without checking museum's
# source. fill_secret is no-op when value already set, so re-runs are safe and
# you can migrate by copying an existing services/ente/.env in.
fill_secret services/ente/.env ENTE_DB_PASSWORD     "$(openssl rand -base64 21 | tr -d '\n')"
fill_secret services/ente/.env ENTE_MINIO_USER      "minio-$(openssl rand -base64 6 | tr -d '\n+/=')"
fill_secret services/ente/.env ENTE_MINIO_PASSWORD  "$(openssl rand -base64 21 | tr -d '\n')"
fill_secret services/ente/.env ENTE_MUSEUM_KEY      "$(openssl rand -base64 32 | tr -d '\n')"
fill_secret services/ente/.env ENTE_MUSEUM_HASH     "$(openssl rand -base64 64 | tr -d '\n')"
# JWT secret uses URL-safe base64 (per Ente's quickstart.sh: sodium_base64_VARIANT_URLSAFE).
fill_secret services/ente/.env ENTE_JWT_SECRET      "$(openssl rand -base64 32 | tr -d '\n' | tr '+/' '-_')"

# ─── Ente museum.yaml render ─────────────────────────────────────────────────
# museum.yaml is mounted into the ente-museum container; its content depends
# on per-deploy values (BASE_DOMAIN, generated secrets). We render it once
# from services/ente/museum.yaml.template and write to ${DATA_PATH}/ente/
# museum.yaml. Skip on re-runs so hand edits to the rendered file survive.
#
# Footgun: the template ships with permissive defaults so first-install
# signup works (`disable-registration: false`, `admins:` unset). If you `rm`
# the rendered file and re-run setup.sh to pick up template changes, your
# runtime customizations (admin user IDs, registration lockdown) are wiped
# and the next museum restart re-opens registration to the world. We can't
# detect this from inside setup.sh after the fact, so loud warnings + an
# auto-backup-of-existing-file are the mitigations:
ente_museum_yaml="$DATA_PATH/ente/museum.yaml"
ente_museum_template="services/ente/museum.yaml.template"

if [[ -f "$ente_museum_yaml" ]]; then
	# Auto-backup so re-rendering can be undone. Cheap insurance.
	# Filename includes a unix timestamp so multiple backups don't collide.
	cp "$ente_museum_yaml" "$ente_museum_yaml.bak.$(date +%s)"
fi

if [[ ! -f "$ente_museum_yaml" ]]; then
	# Either fresh install OR user explicitly rm'd to force re-render.
	log "Rendering $ente_museum_yaml from museum.yaml.template"
	# shellcheck disable=SC1091
	set -a; source services/ente/.env; set +a
	# Allowlist substitution to avoid clobbering any other $VAR-shaped strings
	# the template might gain in the future.
	envsubst '$BASE_DOMAIN $ENTE_DB_PASSWORD $ENTE_MINIO_USER $ENTE_MINIO_PASSWORD $ENTE_MUSEUM_KEY $ENTE_MUSEUM_HASH $ENTE_JWT_SECRET' \
		< "$ente_museum_template" > "$ente_museum_yaml"
	# If a backup exists from a previous render, this is almost certainly a
	# re-render after rm — warn loudly so admin remembers to re-apply runtime
	# customizations (internal.admins, disable-registration, etc.) before the
	# next museum restart.
	latest_bak=$(ls -1t "$ente_museum_yaml".bak.* 2>/dev/null | head -1 || true)
	if [[ -n "$latest_bak" ]]; then
		warn "museum.yaml was just regenerated from template — runtime customizations from the previous version are NOT carried over."
		warn "Compare against the backup and re-apply admin/disable-registration before restarting museum:"
		warn "    diff $latest_bak $ente_museum_yaml"
		warn "Specifically AT RISK on re-render: internal.admins, internal.disable-registration."
	fi
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
# docker compose up handles pull + build transparently: pulls registry images,
# builds services with a build: directive (like our custom Caddy).
log "Starting the stack (first run builds custom Caddy image, ~2 min)"
docker compose up -d

log "Stack is up. Check status with: docker compose ps"
echo
cat <<EOF
Next steps:

  1. Watch Caddy obtain certs: docker compose logs -f caddy
     (First boot takes 30-60s for DNS-01 challenges + LE issuance.)

  2. Open https://id.${BASE_DOMAIN}/signup/setup to bootstrap the first Pocket ID admin user.
     (The /signup/setup path is required only for the very first admin — visiting just / shows
     a login page that can't help you when no account exists yet.)

  3. Wire OIDC into Jellyfin and onboard the first Ente user — see docs/ONBOARDING.md.
     (Ente Photos has no native OIDC; members onboard via email-OTT and store
     their Ente password in their Pocket-ID-SSO'd Vaultwarden vault.)
EOF
