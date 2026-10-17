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
INSTALL_OMLX=0
FETCH_MODELS=0
CUTOVER=0
for arg in "$@"; do
	case "$arg" in
		--upgrade-ollama) UPGRADE=1 ;;
		--install-omlx)   INSTALL_OMLX=1 ;;
		--fetch-omlx-models) FETCH_MODELS=1 ;;
		--cutover)        CUTOVER=1 ;;
		*) die "unknown argument: $arg (expected --upgrade-ollama, --install-omlx, --fetch-omlx-models or --cutover)" ;;
	esac
done

AGENTS="$HOME/Library/LaunchAgents"
STATE="$HOME/.coralstack"
mkdir -p "$AGENTS" "$STATE" "$STATE/logs"      # LaunchAgents may not exist on a fresh Mac

# Which runtime is declared to be serving. Read once, used in several places.
PRIMARY="$(sed -n 's/^MINI_PRIMARY_RUNTIME=//p' "$HERE/versions.env" | tr -d '"' | head -1)"
PRIMARY="${PRIMARY:-ollama}"
[[ "$PRIMARY" == omlx || "$PRIMARY" == ollama ]] \
	|| die "MINI_PRIMARY_RUNTIME is '$PRIMARY' — expected omlx or ollama"

# ─── The chunked downloader, shared by both runtimes ─────────────────────────
# CHUNKED, BECAUSE A SINGLE LONG STREAM DOES NOT SURVIVE THIS PATH. Measured
# from the mini, same interface, back to back:
#   speed.cloudflare.com, one stream ....... 5.1  MB/s
#   GitHub asset, one long stream .......... 0.35 MB/s, stalls dead
#   GitHub asset, 8MB ranged request ....... 5.5  MB/s
# So neither the link nor the CDN is slow — sustained single connections to it
# degrade and then wedge. Short ranged requests do not.
#
# This also fixes resume, which `curl -C -` could NOT do here: each retry
# re-requests the github.com URL, gets a FRESH signed redirect to
# release-assets.githubusercontent.com, and that new URL answers 200 rather than
# 206 — so curl truncated the output file to zero and started over, every time,
# forever. Fetching explicit ranges sidesteps the whole problem: each chunk
# follows its own redirect, and progress lands in .part on disk.
#
# It matters more for oMLX than it ever did for Ollama: the DMG is 792 MiB
# against Ollama's 188, so this is ~100 chunks rather than ~24, and a path that
# wedges mid-download is the difference between a few minutes and never.
#
# ─── Stopping and starting Ollama ────────────────────────────────────────────
# `pkill` IS NOT A DURABLE STOP, which the first cutover discovered the hard
# way: Ollama came straight back with PPID 1. The Mac app registers itself
# through SMAppService, which shows up as the launchd service
# `com.ollama.ollama` in the GUI domain, and launchd respawns it. That is the
# same Login Item machinery com.ollama.host.sh already guards a boot race
# against — here it is the thing that undoes the stop.
#
# WORSE, AND THE REASON THIS MATTERS BEYOND TIDINESS: with the login item left
# enabled, a reboot starts Ollama alongside oMLX. 48 GB does not hold both, and
# "alternating between two conversations works after a reboot" is one of the
# acceptance criteria — so the reboot case would have been the one that failed,
# confusingly, long after the cutover looked fine.
#
# `launchctl disable` persists across reboots, which is exactly the property
# wanted here, and start_ollama re-enables it so a rollback is symmetric.
OLLAMA_SVC="com.ollama.ollama"

stop_ollama() {
	local uid; uid="$(id -u)"
	log "Stopping Ollama and disabling its login item ($OLLAMA_SVC)"

	# DISABLE BEFORE BOOTOUT. THE ORDER IS THE WHOLE FIX.
	#
	# This function used to bootout first, and Ollama came back every time,
	# ~2 seconds later, with PPID 1 and --fast-startup. Booting out a service
	# that launchd is keeping alive gets it relaunched once; the `disable`
	# landed after that decision, and the `pkill` below had already run, so
	# the relaunched instance survived. Proved by hand on 2026-10-16: disable
	# first, then kill, and it stayed down through 60s of watching, where the
	# bootout-first order revived it four runs in a row.
	launchctl disable "gui/$uid/$OLLAMA_SVC" 2>/dev/null || true
	launchctl bootout "gui/$uid/$OLLAMA_SVC" 2>/dev/null || true

	# AppleScript quit needs GUI permission and hangs headless — signals only.
	local attempt
	for attempt in 1 2; do
		pkill -if 'Ollama.app' 2>/dev/null || true
		pkill -ix ollama 2>/dev/null || true
		sleep 3
		pgrep -x ollama >/dev/null 2>&1 || return 0
		warn "ollama still running after attempt $attempt — retrying"
	done

	# Not a `die`: the caller decides. --cutover treats it as fatal because
	# two resident runtimes do not fit; --upgrade-ollama does not care as much.
	warn "ollama is STILL running after disable+bootout+2 kills."
	warn "  Check: launchctl print-disabled gui/$uid | grep ollama"
	return 1
}

# ─── Replacing a launchd agent without racing it ─────────────────────────────
# `launchctl bootstrap` straight after `bootout` fails with "Bootstrap failed:
# 5: Input/output error" while the old job is still unloading — and a graceful
# shutdown is not instant, so this is likely rather than rare for a server.
#
# That is how the third cutover attempt ended with NOTHING running: the bootout
# succeeded, the bootstrap silently failed, the readiness wait correctly found
# no server, and the fail-back fired. The bug was not the race, it was ignoring
# bootstrap's exit status and calling it bootstrapped.
#
# load_agent <label> <plist>
load_agent() {
	local label="$1" plist="$2" uid; uid="$(id -u)"
	launchctl bootout "gui/$uid/$label" 2>/dev/null || true
	# Wait for it to actually be gone before trying to replace it.
	local i
	for i in $(seq 1 30); do
		launchctl print "gui/$uid/$label" >/dev/null 2>&1 || break
		sleep 1
	done
	launchctl print "gui/$uid/$label" >/dev/null 2>&1 \
		&& die "$label is still loaded after 30s of bootout — check launchctl print gui/$uid/$label"
	launchctl bootstrap "gui/$uid" "$plist" \
		|| die "launchctl bootstrap of $label failed — the agent is NOT running"
}

start_ollama() {
	log "Re-enabling and starting Ollama"
	launchctl enable "gui/$(id -u)/$OLLAMA_SVC" 2>/dev/null || true
	open -a Ollama 2>/dev/null || warn "could not launch Ollama.app"
	sleep 5
}

# fetch_chunked <url> <final-path>
fetch_chunked() {
	local url="$1" final="$2"
	local part="${final}.part"
	local CHUNK=8000000
	local total start stop code got

	total="$(curl -fsIL -m 30 "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{n=$2} END{print n}')"
	[[ "$total" =~ ^[0-9]+$ ]] || die "could not determine the download size (content-length missing)"

	# Already complete? Makes this idempotent per FILE, which is what lets the
	# model fetch below be re-run after an interruption without re-pulling the
	# shards it already has — 15 GB in three pieces, and only the unfinished
	# one should cost anything.
	if [[ -f "$final" ]] && (( $(stat -f %z "$final" 2>/dev/null || echo 0) == total )); then
		log "already have $(basename "$final") ($((total / 1000000)) MB)"
		return 0
	fi

	start=0
	[[ -f "$part" ]] && start="$(stat -f %z "$part" 2>/dev/null || echo 0)"
	(( start > total )) && { rm -f "$part"; start=0; }   # stale/corrupt partial
	(( start > 0 )) && log "resuming at $((start / 1000000))MB"

	while (( start < total )); do
		stop=$(( start + CHUNK - 1 ))
		(( stop >= total )) && stop=$(( total - 1 ))

		# Require 206. A 200 here means the server ignored the Range and is
		# sending the WHOLE file, which appended to .part would silently produce
		# a corrupt archive that still unpacks far enough to look plausible.
		code="$(curl -fL -s -m 120 --retry 5 --retry-all-errors --retry-delay 2 \
			-r "${start}-${stop}" -o "${part}.chunk" -w '%{http_code}' "$url" || echo 000)"
		[[ "$code" == 206 ]] || die "chunk at byte $start returned HTTP $code (expected 206) — re-run to resume"

		got="$(stat -f %z "${part}.chunk" 2>/dev/null || echo 0)"
		(( got == stop - start + 1 )) || die "chunk at byte $start was $got bytes, expected $(( stop - start + 1 )) — re-run to resume"

		cat "${part}.chunk" >> "$part"
		rm -f "${part}.chunk"
		start=$(( start + got ))
		printf '\r[mini-install] %s / %s MB' "$((start / 1000000))" "$((total / 1000000))"
	done
	echo

	got="$(stat -f %z "$part" 2>/dev/null || echo 0)"
	(( got == total )) || die "assembled $got bytes, expected $total — re-run to resume"
	mv "$part" "$final"
}

# ─── Optional: upgrade the Ollama app to the pinned version ──────────────────
# Deliberately NOT part of the daily reconcile. This replaces an application
# bundle on a running host; the timer reports the skew and a human runs this.
if (( UPGRADE )); then
	want="$(sed -n 's/^OLLAMA_VERSION=//p' "$HERE/versions.env" | tr -d '"' | head -1)"
	[[ -n "$want" ]] || die "no OLLAMA_VERSION in versions.env"
	# MATCH THE VERSION LINE. With the server stopped — now its normal state as
	# the rollback runtime — `ollama --version` prints a "could not connect"
	# warning first, and `awk '{print $NF}'` over every line returned that
	# warning's last word glued to the version. It never equalled the pin, so
	# this re-downloaded and reinstalled 188 MB on every single run.
	have="$(/usr/local/bin/ollama --version 2>/dev/null | sed -n 's/.*version is //p' | head -1)"
	have="${have:-none}"

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

		log "Downloading $url (chunked)"
		fetch_chunked "$url" "$tmp/Ollama.zip"

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

		# The durable stop, not a bare pkill: launchd respawns this app from
		# its SMAppService login item, which would both fight the bundle
		# replacement below and — if oMLX is the primary — bring Ollama back
		# up alongside it. start_ollama re-enables the login item, and is
		# called below only when Ollama is the runtime that serves.
		stop_ollama || true   # upgrade can proceed; the bundle swap just needs it down-ish

		log "Replacing /Applications/Ollama.app"
		rm -rf /Applications/Ollama.app
		ditto "$tmp/unpacked/Ollama.app" /Applications/Ollama.app || die "install failed — reinstall from ollama.com"

		# ONLY RESTART IT IF IT IS THE RUNTIME THAT SERVES. Upgrading the
		# rollback runtime must not bring it back up alongside oMLX: that is
		# 18 GB of weights landing on top of oMLX's ~25 GB on a 48 GB box, and
		# the upgrade is otherwise a perfectly reasonable thing to do while
		# oMLX is serving.
		if [[ "$PRIMARY" == ollama ]]; then
			start_ollama
			log "Now: $(/usr/local/bin/ollama --version 2>&1 | tail -1)"
		else
			log "Upgraded the bundle and left Ollama STOPPED and its login item"
			log "  disabled — $PRIMARY is the primary runtime."
		fi

		# Only now is the resume cache dead weight — 190MB of it.
		rm -rf "$tmp/Ollama.zip" "$tmp/unpacked"
	fi
fi

# ─── Optional: install oMLX from its signed DMG ──────────────────────────────
# Same shape as the Ollama upgrade above and for the same reason: this writes an
# application bundle, so a human asks for it and the timer never does.
#
# THE BUNDLE DOES NOT GO IN /Applications, on purpose. It contains a GUI app
# with an in-app updater — the exact mechanism that left Ollama three minor
# versions behind on this headless box and then applied an update nobody asked
# for. launchd runs `omlx-cli`, a different executable in the same bundle with
# zero update-check symbols in it (measured 2026-10-16: 0, against 6 in the GUI
# binary). Keeping the bundle out of /Applications means the GUI binary cannot
# be reached by a double-click or a Login Item, so "we never launch the app" is
# a property of the install rather than a convention someone has to remember.
# The reconcile reports a copy appearing in /Applications as a finding.
if (( INSTALL_OMLX )); then
	want="$(sed -n 's/^OMLX_VERSION=//p' "$HERE/versions.env" | tr -d '"' | head -1)"
	[[ -n "$want" ]] || die "no OMLX_VERSION in versions.env"
	want_team="$(sed -n 's/^OMLX_TEAM_ID=//p' "$HERE/versions.env" | tr -d '"' | head -1)"
	app="$STATE/oMLX.app"
	have="$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo none)"

	if [[ "$have" == "$want" ]]; then
		log "oMLX already at $want — nothing to do"
	else
		log "Installing oMLX $have → $want"
		tmp="$STATE/downloads"
		mkdir -p "$tmp"
		rm -rf "$tmp/omlx-unpacked"

		# Upstream ships one DMG per macOS generation and they are NOT
		# interchangeable — 0.7.0 carries macos15-sequoia and macos26-27. Pick
		# by the running OS so this script is correct on either, rather than
		# hardcoding the one the mini happens to run today (26.3).
		osmajor="$(sw_vers -productVersion | cut -d. -f1)"
		if (( osmajor >= 26 )); then
			dmg_name="oMLX-${want}-macos26-27.dmg"
		else
			dmg_name="oMLX-${want}-macos15-sequoia.dmg"
		fi
		url="https://github.com/jundot/omlx/releases/download/v${want}/${dmg_name}"

		log "Downloading $url (chunked, ~790MB)"
		fetch_chunked "$url" "$tmp/$dmg_name"

		# A DMG, not a zip, so mount-and-copy rather than `ditto -x -k`. The
		# trap detaches even when a check below fails — a leaked mount means
		# the next run cannot reuse the mountpoint and fails confusingly.
		mnt="$tmp/omlx-mnt"
		mkdir -p "$mnt"
		# shellcheck disable=SC2064
		trap "hdiutil detach '$mnt' >/dev/null 2>&1 || true" EXIT
		hdiutil attach "$tmp/$dmg_name" -nobrowse -readonly -mountpoint "$mnt" >/dev/null \
			|| die "could not mount $dmg_name (corrupt? delete it and re-run)"
		[[ -d "$mnt/oMLX.app" ]] || die "no oMLX.app in the mounted image"

		mkdir -p "$tmp/omlx-unpacked"
		ditto "$mnt/oMLX.app" "$tmp/omlx-unpacked/oMLX.app" || die "copy out of the image failed"
		hdiutil detach "$mnt" >/dev/null 2>&1 || true
		trap - EXIT

		# Verify BEFORE anything is installed and before the quarantine flag is
		# cleared. A tampered or truncated download must not become the binary
		# that answers on 0.0.0.0.
		log "Verifying code signature"
		codesign --verify --deep --strict "$tmp/omlx-unpacked/oMLX.app" \
			|| die "code signature verification FAILED — refusing to install"
		team="$(codesign -dv --verbose=4 "$tmp/omlx-unpacked/oMLX.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
		if [[ -n "$want_team" ]]; then
			[[ "$team" == "$want_team" ]] \
				|| die "signed by TeamIdentifier=$team, expected $want_team — refusing to install"
			log "Signer matches the pin (TeamIdentifier=$team)"
		else
			log "Signed by TeamIdentifier=$team — put this in versions.env as OMLX_TEAM_ID to pin it"
		fi

		got="$(defaults read "$tmp/omlx-unpacked/oMLX.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
		[[ "$got" == "$want" ]] || die "image claims version $got, expected $want — refusing to install"

		cli="$tmp/omlx-unpacked/oMLX.app/Contents/MacOS/omlx-cli"
		[[ -x "$cli" ]] || die "no omlx-cli in the bundle at Contents/MacOS/omlx-cli"

		# THE FLAGS ARE PART OF THE CONTRACT, so check they still exist before
		# this becomes a KeepAlive agent. A flag upstream renamed would
		# otherwise turn into a 30-second crash loop whose only symptom is a
		# log file nobody is reading.
		log "Checking the declared flags against omlx-cli serve --help"
		help="$("$cli" serve --help 2>&1 || true)"
		# Fall back to the top-level help if `serve --help` is not how this
		# version spells it. Without this, an invocation change would fail the
		# flag loop below and report every flag as missing, which points at
		# entirely the wrong thing.
		grep -q -- '--model-dir' <<<"$help" || help="$("$cli" --help 2>&1 || true)"
		if ! grep -q -- '--model-dir' <<<"$help"; then
			die "could not read a flag list from omlx-cli $want (tried 'serve --help' and '--help') — check the CLI by hand before installing"
		fi
		# Mirrors exactly what omlx-serve.sh passes. Keep the two in step: a
		# flag checked here but not passed is noise, and one passed but not
		# checked is the crash loop this exists to prevent.
		for flag in --host --port --model-dir --paged-ssd-cache-dir \
		            --paged-ssd-cache-max-size --hot-cache-max-size \
		            --memory-guard --max-concurrent-requests
		do
			grep -q -- "$flag" <<<"$help" \
				|| die "omlx-cli $want does not accept $flag — omlx-serve.sh needs updating before this can be installed"
		done

		log "Installing to $app"
		if launchctl print "gui/$(id -u)/com.coralstack.omlx" >/dev/null 2>&1; then
			log "Stopping the running oMLX agent first"
			launchctl bootout "gui/$(id -u)/com.coralstack.omlx" 2>/dev/null || true
			sleep 2
		fi
		rm -rf "$app"
		ditto "$tmp/omlx-unpacked/oMLX.app" "$app" || die "install failed"

		# Only after the signature checked out. curl sets com.apple.quarantine
		# on the download and it propagates into the copy; left in place, the
		# first exec of a quarantined binary is refused on a box with no GUI
		# session to approve it.
		xattr -dr com.apple.quarantine "$app" 2>/dev/null || true

		log "Installed: $("$app/Contents/MacOS/omlx-cli" --version 2>&1 | head -1)"
		rm -rf "$tmp/$dmg_name" "$tmp/omlx-unpacked"
	fi
fi

# ─── Optional: fetch the declared oMLX models from Hugging Face ──────────────
# WHY THIS IS A FLAG AND NOT PART OF THE DAILY RECONCILE, when `ollama pull` IS
# automatic there. MAC_MINI.md's risk inversion says model pulls are additive,
# reversible and cheap on this host, and that still holds — but `ollama pull` is
# one resumable, self-verifying command, while this is a multi-file ranged
# download whose provenance we have to establish ourselves. The downloader
# lives here, a human is present for 15 GB, and the reconcile reports what is
# missing. Documented as a divergence in docs/MAC_MINI.md rather than a silent
# exception.
#
# THE SIDECAR IS THE POINT. oMLX's --model-dir layout records no revision, so a
# directory on disk cannot say which conversion it holds. Writing
# .coralstack-revision next to the model is what makes the pin in
# omlx-models.txt verifiable afterwards, and an unpinned conversion is the
# regression that is hardest to see from a chat window: the numerics of a
# quantisation can change under a rewritten branch with no version to bump.
if (( FETCH_MODELS )); then
	[[ -r "$HERE/omlx-models.txt" ]] || die "no omlx-models.txt beside this script"
	command -v jq >/dev/null 2>&1 || die "jq is needed to read the Hugging Face file list (it ships at /usr/bin/jq on macOS)"

	model_dir="$(sed -n 's/^OMLX_MODEL_DIR=//p' "$STATE/omlx.env" 2>/dev/null | tr -d '"' | head -1)"
	model_dir="${model_dir:-$HOME/.omlx/models}"

	while IFS= read -r line; do
		line="${line%%#*}"
		line="$(echo "$line" | tr -d '[:space:]')"
		[[ -z "$line" ]] && continue
		repo="${line%@*}"
		rev="${line#*@}"
		[[ "$repo" != "$line" ]] || die "no @revision in '$line' — pin a revision, never a branch"

		log "Fetching $repo at $rev"
		meta="$(curl -fsS -m 60 "https://huggingface.co/api/models/${repo}/revision/${rev}")" \
			|| die "could not read $repo at revision $rev from Hugging Face"
		# Resolve the short pin to the full commit, so the sidecar records
		# something unambiguous even when the file says 7 characters.
		full_rev="$(jq -r '.sha' <<<"$meta")"
		[[ -n "$full_rev" && "$full_rev" != null ]] || die "no .sha for $repo at $rev"

		dest="$model_dir/$repo"
		mkdir -p "$dest"
		while IFS= read -r f; do
			[[ -z "$f" ]] && continue
			mkdir -p "$dest/$(dirname "$f")"
			fetch_chunked \
				"https://huggingface.co/${repo}/resolve/${full_rev}/${f}" \
				"$dest/$f"
		done < <(jq -r '.siblings[].rfilename' <<<"$meta")

		# Written LAST, so an interrupted fetch leaves no sidecar and the
		# reconcile reports an unverifiable model rather than a complete one.
		printf '%s\n' "$full_rev" > "$dest/.coralstack-revision"
		log "$repo complete at $full_rev"
	done < "$HERE/omlx-models.txt"
fi

# ─── The Ollama environment agent ────────────────────────────────────────────
# The FILES are always installed, so a rollback has them ready. Whether the
# AGENT runs depends on which runtime serves, and that distinction is
# load-bearing rather than tidiness.
#
# This agent exists only to hand the Ollama GUI app five env vars and to
# self-heal if the Login Item won the boot race. With Ollama stopped, the first
# job is meaningless and the second is actively harmful: the self-heal's job is
# to start Ollama, so leaving it loaded while oMLX serves means a stray
# invocation can resurrect the runtime the cutover just stopped — which is what
# happened on 2026-10-16, seconds after the first cutover, via `open -a
# Ollama`. Both runtimes do not fit in 48 GB.
log "Installing the Ollama env LaunchAgent files"
install -m 0755 "$HERE/com.ollama.host.sh" "$AGENTS/com.ollama.host.sh"
sed "s|__HOME__|$HOME|g" "$HERE/com.ollama.host.plist.template" > "$AGENTS/com.ollama.host.plist"

# `launchctl load` no longer runs RunAtLoad reliably on modern macOS; bootstrap
# into the GUI domain instead. bootout first so a re-run replaces cleanly.
if [[ "$PRIMARY" == ollama ]]; then
	load_agent com.ollama.host "$AGENTS/com.ollama.host.plist"
	launchctl kickstart -k "gui/$(id -u)/com.ollama.host"  # simulate a fresh login
else
	launchctl bootout "gui/$(id -u)/com.ollama.host" 2>/dev/null || true
	log "  left UNLOADED — $PRIMARY serves, so Ollama needs no env and must not be revived"
fi

# ─── The reconcile agent ─────────────────────────────────────────────────────
log "Installing the reconcile script and its declared state"
install -m 0755 "$HERE/ollama-reconcile.sh" "$STATE/ollama-reconcile.sh"
install -m 0644 "$HERE/models.txt"          "$STATE/models.txt"
install -m 0644 "$HERE/omlx-models.txt"     "$STATE/omlx-models.txt"
install -m 0644 "$HERE/versions.env"        "$STATE/versions.env"

if [[ -f "$STATE/ollama.env" ]]; then
	log "$STATE/ollama.env exists — leaving it alone"
else
	install -m 0600 "$HERE/ollama.env.example" "$STATE/ollama.env"
	log "Wrote $STATE/ollama.env from the example — EDIT IT NOW:"
	log "  HEALTHCHECK_URL must be the Uptime Kuma push URL, or you get no alerts."
	log "  It is the PUBLIC https://status.<domain>/api/push/<token> form, printed"
	log "  as step 6 of setup.sh on the apps VM (OLLAMA_MINI_PUSH_TOKEN)."
fi

# ─── The oMLX serve agent ────────────────────────────────────────────────────
# Installed whether or not oMLX is the declared primary, so a rollback in
# either direction is one line in versions.env plus a re-run — never a
# re-install under pressure.
log "Installing the oMLX serve wrapper and its config"
install -m 0755 "$HERE/omlx-serve.sh" "$STATE/omlx-serve.sh"

if [[ -f "$STATE/omlx.env" ]]; then
	log "$STATE/omlx.env exists — leaving it alone"
else
	install -m 0600 "$HERE/omlx.env.example" "$STATE/omlx.env"
	# Generate the key here rather than making a human invent one. oMLX will
	# not bind a non-loopback host without it, so an empty value is not a
	# degraded install, it is a server that refuses to start.
	key="$(openssl rand -hex 32)"
	sed -i '' "s|^OMLX_API_KEY=.*|OMLX_API_KEY=$key|" "$STATE/omlx.env"
	log "Wrote $STATE/omlx.env with a freshly generated API key."
	log "  THIS VALUE IS PRINTED ONCE. It has to reach two other places by hand:"
	log "    - services/open-webui/.env on the apps VM, as OMLX_API_KEY"
	log "    - the Perennial client's own config, in its own repo"
	log "  OMLX_API_KEY=$key"
fi

sed "s|__HOME__|$HOME|g" "$HERE/com.coralstack.omlx.plist.template" \
	> "$AGENTS/com.coralstack.omlx.plist"

log "Installing the reconcile LaunchAgent (daily 06:35)"
sed "s|__HOME__|$HOME|g" "$HERE/com.coralstack.ollama-reconcile.plist.template" \
	> "$AGENTS/com.coralstack.ollama-reconcile.plist"
load_agent com.coralstack.ollama-reconcile "$AGENTS/com.coralstack.ollama-reconcile.plist"

# ─── Which runtime actually serves ───────────────────────────────────────────
# ONE RULE GOVERNS THIS WHOLE BLOCK: nothing here stops Ollama without being
# asked to. The mini is serving the household's chat, and 48 GB cannot hold
# both runtimes' weights and caches, so the switch is a deliberate act with a
# flag of its own rather than a side effect of running the installer.
omlx_installed=0
[[ -x "$STATE/oMLX.app/Contents/MacOS/omlx-cli" ]] && omlx_installed=1

# `ollama ps` lists RESIDENT models, which is the question that matters. A
# running-but-idle Ollama costs nothing; one holding 18-33 GB of weights is
# what collides with oMLX. An empty list (header only) means nothing is loaded.
ollama_resident=0
if /usr/local/bin/ollama ps >/dev/null 2>&1; then
	[[ -n "$(/usr/local/bin/ollama ps 2>/dev/null | awk 'NR>1 && NF {print}')" ]] && ollama_resident=1
fi

if [[ "$PRIMARY" == omlx ]]; then
	if (( ! omlx_installed )); then
		log "versions.env declares oMLX primary, but oMLX is not installed yet."
		log "  Run: bash $HERE/install.sh --install-omlx"
	elif (( CUTOVER )); then
		log "CUTOVER: stopping Ollama and starting oMLX"
		# Fatal here, unlike in the upgrade path: starting oMLX on top of a
		# live Ollama is the 48 GB collision this whole design exists to
		# prevent, so refuse rather than create it.
		stop_ollama || die "refusing to start oMLX while Ollama is still running — both runtimes do not fit in 48 GB"

		load_agent com.coralstack.omlx "$AGENTS/com.coralstack.omlx.plist"

		# WAIT FOR IT TO ACTUALLY SERVE, AND FAIL BACK IF IT DOES NOT.
		# The first version of this reported success the moment launchd
		# accepted the job, which is not the same thing at all: on
		# 2026-10-16 it printed "oMLX agent bootstrapped" over a KeepAlive
		# crash loop caused by one bad flag value, and left the box with
		# nothing serving the household. A cutover that cannot verify the
		# new server is not a cutover, it is an outage with a success
		# message.
		key="$(sed -n 's/^OMLX_API_KEY=//p' "$STATE/omlx.env" | head -1)"
		port="$(sed -n 's/^OMLX_PORT=//p' "$STATE/omlx.env" | head -1)"
		port="${port:-8000}"
		log "Waiting for oMLX to answer on :$port (up to 180s)"
		ready=0
		for _ in $(seq 1 60); do
			if curl -fsS -m 5 -o /dev/null \
				-H "Authorization: Bearer $key" \
				"http://127.0.0.1:${port}/v1/models" 2>/dev/null; then
				ready=1; break
			fi
			sleep 3
		done

		if (( ready )); then
			log "oMLX is serving on :$port. Ollama is stopped and its login item"
			log "  is disabled, so a reboot will not bring it back alongside oMLX."
			log "  Rollback: MINI_PRIMARY_RUNTIME=ollama in versions.env plus a re-run."
		else
			warn "oMLX did NOT come up within 180s. Failing back to Ollama."
			warn "Last 15 lines of $STATE/logs/omlx.log:"
			tail -15 "$STATE/logs/omlx.log" 2>&1 | sed 's/^/    /' >&2
			launchctl bootout "gui/$(id -u)/com.coralstack.omlx" 2>/dev/null || true
			start_ollama
			die "cutover aborted; Ollama restored. Fix the above, then re-run --cutover."
		fi
	elif (( ollama_resident )); then
		# Deliberately NOT starting oMLX here. Whether oMLX preloads the models
		# it finds in --model-dir at startup is unverified, and if it does, that
		# is 15.45 GB landing on top of Ollama's resident 18-33 GB on a 48 GB
		# box that is currently answering the household. Not worth finding out
		# by accident.
		log "Ollama still holds a model resident, so oMLX was NOT started."
		log "  The agent is installed and ready. To complete the cutover:"
		log "    bash $HERE/install.sh --cutover"
	else
		log "Nothing resident in Ollama — starting the oMLX agent"
		load_agent com.coralstack.omlx "$AGENTS/com.coralstack.omlx.plist"
	fi
else
	# Declared primary is Ollama. If the oMLX agent is loaded, this run IS the
	# rollback, so take it down — that is the whole point of the flag flip.
	if launchctl print "gui/$(id -u)/com.coralstack.omlx" >/dev/null 2>&1; then
		log "versions.env declares Ollama primary — stopping the oMLX agent"
		launchctl bootout "gui/$(id -u)/com.coralstack.omlx" 2>/dev/null || true
	fi
	# A rollback has to UNDO the disable, or Ollama stays down across reboots
	# and the box serves nothing at all — the one failure worse than either
	# runtime being wrong.
	if ! pgrep -x ollama >/dev/null 2>&1; then
		start_ollama
	fi
	(( omlx_installed )) && log "oMLX stays installed as the forward path; nothing serving from it."
fi

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
  bash $STATE/ollama-reconcile.sh --apply      # fetch declared-but-missing models
  bash $HERE/install.sh --upgrade-ollama       # upgrade Ollama to the pinned version
  bash $HERE/install.sh --install-omlx         # install oMLX from its signed DMG

Declared primary runtime: $PRIMARY (MINI_PRIMARY_RUNTIME in versions.env).
  bash $HERE/install.sh --cutover              # stop Ollama, start oMLX

Nothing in this script stops Ollama except --cutover, and the box only ever
serves from one runtime at a time — 48 GB does not hold both. Rollback is one
line in versions.env plus a re-run. See docs/MAC_MINI.md.
DONE
