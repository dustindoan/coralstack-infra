#!/usr/bin/env bash
# Install the SMART check on the PROXMOX HOST (not the apps VM).
#
# Run this ON the NUC, as root, from a checkout of this repo:
#   bash services/smart/host/install.sh
#
# Idempotent: re-running upgrades the script and units in place and leaves your
# existing /etc/coralstack/smart.env alone.
set -euo pipefail

log() { printf '\033[1;36m[smart-install]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[smart-install]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (installs into /usr/local/bin and /etc/systemd/system)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$HERE/../smart-check.sh" ]] || die "can't find ../smart-check.sh — run this from the repo checkout"

log "Installing smartmontools, jq, curl"
apt-get update -qq
apt-get install -y -qq smartmontools jq curl

log "Installing smart-check.sh → /usr/local/bin/"
install -m 0755 "$HERE/../smart-check.sh" /usr/local/bin/smart-check.sh

mkdir -p /etc/coralstack /var/lib/coralstack
if [[ -f /etc/coralstack/smart.env ]]; then
	log "/etc/coralstack/smart.env exists — leaving it alone"
else
	install -m 0600 "$HERE/smart.env.example" /etc/coralstack/smart.env
	log "Wrote /etc/coralstack/smart.env from the example — EDIT IT NOW:"
	log "  - SMART_DEVICES must match this box (lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL)"
	log "  - HEALTHCHECK_URL must be the Uptime Kuma push URL, or you get no alerts"
fi

log "Installing systemd units"
install -m 0644 "$HERE/coralstack-smart.service" /etc/systemd/system/
install -m 0644 "$HERE/coralstack-smart.timer"   /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now coralstack-smart.timer

log "Running the check once now, so a misconfiguration surfaces immediately"
# Don't let a FINDING (exit 1) abort the installer — that's the check working.
set +e
systemctl start coralstack-smart.service
systemctl status coralstack-smart.service --no-pager -l | tail -20
set -e

cat <<'DONE'

Installed. Verify:
  systemctl list-timers coralstack-smart.timer
  journalctl -u coralstack-smart -n 50

If the run said "cannot read SMART data" or "No devices to check", that is a
CONFIG problem, not a disk problem — fix SMART_DEVICES in
/etc/coralstack/smart.env and re-run: systemctl start coralstack-smart.service
DONE
