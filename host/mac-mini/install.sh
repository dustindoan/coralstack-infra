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
		# NOT mktemp -d: `curl -C -` can only resume if the partial file is still
		# there next run, and a temp dir wiped on EXIT defeats that. This cache
		# survives a failed attempt so a re-run picks up where it stopped.
		tmp="$STATE/downloads"
		mkdir -p "$tmp"
		rm -rf "$tmp/unpacked"
		url="https://github.com/ollama/ollama/releases/download/v${want}/Ollama-darwin.zip"

		# CHUNKED, BECAUSE A SINGLE LONG STREAM DOES NOT SURVIVE THIS PATH.
		# Measured from the mini, same interface, back to back:
		#   speed.cloudflare.com, one stream ....... 5.1  MB/s
		#   GitHub asset, one long stream .......... 0.35 MB/s, stalls dead
		#   GitHub asset, 8MB ranged request ....... 5.5  MB/s
		# So neither the link nor the CDN is slow — sustained single connections
		# to it degrade and then wedge. Short ranged requests do not.
		#
		# This also fixes resume, which `curl -C -` could NOT do here: each retry
		# re-requests the github.com URL, gets a FRESH signed redirect to
		# release-assets.githubusercontent.com, and that new URL answers 200 rather
		# than 206 — so curl truncated the output file to zero and started over,
		# every time, forever. Fetching explicit ranges sidesteps the whole problem:
		# each chunk follows its own redirect, and progress lands in .part on disk.
		log "Downloading $url (chunked)"
		CHUNK=8000000
		part="$tmp/Ollama.zip.part"

		total="$(curl -fsIL -m 30 "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')"
		[[ "$total" =~ ^[0-9]+$ ]] || die "could not determine the download size (content-length missing)"

		start=0
		[[ -f "$part" ]] && start="$(stat -f %z "$part" 2>/dev/null || echo 0)"
		(( start > total )) && { rm -f "$part"; start=0; }   # stale/corrupt partial
		(( start > 0 )) && log "resuming at $((start / 1000000))MB"

		while (( start < total )); do
			stop=$(( start + CHUNK - 1 ))
			(( stop >= total )) && stop=$(( total - 1 ))

			# Require 206. A 200 here means the server ignored the Range and is
			# sending the WHOLE file, which appended to .part would silently produce
			# a corrupt archive that still unzips far enough to look plausible.
			code="$(curl -fL -s -m 120 --retry 5 --retry-all-errors --retry-delay 2 \
				-r "${start}-${stop}" -o "$tmp/chunk" -w '%{http_code}' "$url" || echo 000)"
			[[ "$code" == 206 ]] || die "chunk at byte $start returned HTTP $code (expected 206) — re-run to resume"

			got="$(stat -f %z "$tmp/chunk" 2>/dev/null || echo 0)"
			(( got == stop - start + 1 )) || die "chunk at byte $start was $got bytes, expected $(( stop - start + 1 )) — re-run to resume"

			cat "$tmp/chunk" >> "$part"
			rm -f "$tmp/chunk"
			start=$(( start + got ))
			printf '\r[mini-install] %s / %s MB' "$((start / 1000000))" "$((total / 1000000))"
		done
		echo

		size="$(stat -f %z "$part" 2>/dev/null || echo 0)"
		(( size == total )) || die "assembled $size bytes, expected $total — re-run to resume"
		mv "$part" "$tmp/Ollama.zip"

		ditto -x -k "$tmp/Ollama.zip" "$tmp/unpacked" || die "unzip failed (archive corrupt? delete it and re-run)"
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

		# Only now is the resume cache dead weight — 190MB of it.
		rm -rf "$tmp/Ollama.zip" "$tmp/unpacked"
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
