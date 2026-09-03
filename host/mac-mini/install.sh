#!/usr/bin/env bash
# Install the CoralStack agents on the MAC MINI (the inference host).
#
# Run this ON the mini, as your normal user (NOT root — these are user
# LaunchAgents and the Ollama app is user-owned), from a checkout of this repo:
#   bash host/mac-mini/install.sh
#
# Optionally upgrade the Ollama app to the version pinned in versions.env:
#   bash host/mac-mini/install.sh --upgrade-ollama
#
# Idempotent: re-running upgrades the scripts and agents in place and leaves an
# existing ~/.coralstack/ollama.env alone. See docs/MAC_MINI.md.
set -euo pipefail

log() { printf '\033[1;36m[mini-install]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[mini-install]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "do NOT run as root — these are user LaunchAgents and /Applications/Ollama.app is user-owned"
[[ "$(uname -s)" == Darwin ]] || die "this installs launchd agents; it only makes sense on the Mac mini"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$HERE/ollama-reconcile.sh" ]] || die "can't find ollama-reconcile.sh — run this from the repo checkout"

UPGRADE=0
for arg in "$@"; do
	case "$arg" in
		--upgrade-ollama) UPGRADE=1 ;;
		*) die "unknown argument: $arg (expected --upgrade-ollama)" ;;
	esac
done

AGENTS="$HOME/Library/LaunchAgents"
STATE="$HOME/.coralstack"
mkdir -p "$AGENTS" "$STATE" "$STATE/logs"      # LaunchAgents may not exist on a fresh Mac

# ─── Optional: upgrade the Ollama app to the pinned version ──────────────────
# Deliberately NOT part of the daily reconcile. This replaces an application
# bundle on a running host; the timer reports the skew and a human runs this.
if (( UPGRADE )); then
	want="$(sed -n 's/^OLLAMA_VERSION=//p' "$HERE/versions.env" | tr -d '"' | head -1)"
	[[ -n "$want" ]] || die "no OLLAMA_VERSION in versions.env"
	have="$(/usr/local/bin/ollama --version 2>/dev/null | awk '{print $NF}' || echo none)"

	if [[ "$have" == "$want" ]]; then
		log "Ollama already at $want — nothing to do"
	else
		log "Upgrading Ollama $have → $want"
		tmp="$(mktemp -d)"
		trap 'rm -rf "$tmp"' EXIT
		url="https://github.com/ollama/ollama/releases/download/v${want}/Ollama-darwin.zip"

		log "Downloading $url"
		curl -fL --progress-bar -o "$tmp/Ollama.zip" "$url" || die "download failed"
		ditto -x -k "$tmp/Ollama.zip" "$tmp/unpacked" || die "unzip failed"
		[[ -d "$tmp/unpacked/Ollama.app" ]] || die "no Ollama.app in the downloaded archive"

		# Verify the signature BEFORE putting it in /Applications. A tampered or
		# truncated download must not become the binary that answers on 0.0.0.0.
		log "Verifying code signature"
		codesign --verify --deep --strict "$tmp/unpacked/Ollama.app" \
			|| die "code signature verification FAILED — refusing to install"
		team="$(codesign -dv --verbose=4 "$tmp/unpacked/Ollama.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
		log "Signed by TeamIdentifier=$team"

		got="$(defaults read "$tmp/unpacked/Ollama.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
		[[ "$got" == "$want" ]] || die "archive claims version $got, expected $want — refusing to install"

		log "Stopping Ollama (AppleScript quit needs GUI permission and hangs headless — signals only)"
		pkill -if 'Ollama.app' 2>/dev/null || true
		pkill -ix ollama 2>/dev/null || true
		sleep 2

		log "Replacing /Applications/Ollama.app"
		rm -rf /Applications/Ollama.app
		ditto "$tmp/unpacked/Ollama.app" /Applications/Ollama.app || die "install failed — reinstall from ollama.com"
		open -a Ollama
		sleep 5
		log "Now: $(/usr/local/bin/ollama --version 2>&1 | head -1)"
	fi
fi

# ─── The Ollama environment agent ────────────────────────────────────────────
log "Installing the Ollama env LaunchAgent"
install -m 0755 "$HERE/com.ollama.host.sh" "$AGENTS/com.ollama.host.sh"
sed "s|__HOME__|$HOME|g" "$HERE/com.ollama.host.plist.template" > "$AGENTS/com.ollama.host.plist"

# `launchctl load` no longer runs RunAtLoad reliably on modern macOS; bootstrap
# into the GUI domain instead. bootout first so a re-run replaces cleanly.
launchctl bootout   "gui/$(id -u)/com.ollama.host" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTS/com.ollama.host.plist"
launchctl kickstart -k "gui/$(id -u)/com.ollama.host"     # simulate a fresh login

# ─── The reconcile agent ─────────────────────────────────────────────────────
log "Installing the reconcile script and its declared state"
install -m 0755 "$HERE/ollama-reconcile.sh" "$STATE/ollama-reconcile.sh"
install -m 0644 "$HERE/models.txt"          "$STATE/models.txt"
install -m 0644 "$HERE/versions.env"        "$STATE/versions.env"

if [[ -f "$STATE/ollama.env" ]]; then
	log "$STATE/ollama.env exists — leaving it alone"
else
	install -m 0600 "$HERE/ollama.env.example" "$STATE/ollama.env"
	log "Wrote $STATE/ollama.env from the example — EDIT IT NOW:"
	log "  HEALTHCHECK_URL must be the Uptime Kuma push URL, or you get no alerts"
fi

log "Installing the reconcile LaunchAgent (daily 06:35)"
sed "s|__HOME__|$HOME|g" "$HERE/com.coralstack.ollama-reconcile.plist.template" \
	> "$AGENTS/com.coralstack.ollama-reconcile.plist"
launchctl bootout   "gui/$(id -u)/com.coralstack.ollama-reconcile" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENTS/com.coralstack.ollama-reconcile.plist"

# ─── First run: REPORT ONLY ──────────────────────────────────────────────────
# Not --apply. A declared model set can be tens of GB and an installer should
# never start that unannounced; the daily job will, or you can now.
log "Running the reconcile once in report-only mode"
set +e
OLLAMA_RECONCILE_ENV="$STATE/ollama.env" bash "$STATE/ollama-reconcile.sh"
set -e

cat <<DONE

Installed. Verify:
  launchctl print gui/$(id -u)/com.coralstack.ollama-reconcile | head -20
  tail -f $STATE/logs/ollama-reconcile.log

The report above lists what's out of sync. To act on it:
  bash $STATE/ollama-reconcile.sh --apply      # pull declared-but-missing models
  bash $HERE/install.sh --upgrade-ollama       # upgrade the app to the pinned version

Both are also what the daily job and Renovate keep honest. Nothing else on this
box is in the deploy model — see docs/MAC_MINI.md.
DONE
