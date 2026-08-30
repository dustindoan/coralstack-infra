#!/usr/bin/env bash
# CoralStack SMART check — turn silent disk degradation into advance warning.
#
# WHY THIS EXISTS: disks almost always announce themselves before they die —
# reallocated sectors, pending sectors, rising temperature, NVMe wear. Nothing
# in the stack was watching for any of that, so the first signal of a failing
# drive would have been the failure itself. See docs/HARDWARE_FAILURE.md.
#
# RUNS IN TWO PLACES, and this script is deliberately host-agnostic so it can
# be the same file in both (pure bash + smartctl + jq + curl, no container
# assumptions):
#   - Apps VM, containerized (services/smart/docker-compose.yml) — sees the
#     TerraMaster, which is USB-passed-through to this VM.
#   - Proxmox host, natively via a systemd timer (services/smart/host/) — sees
#     the NUC's internal SATA SSD. The apps VM CANNOT see it: from inside the VM that
#     disk is a virtio device with no SMART data behind it. This is why one
#     runner isn't enough.
#
# ALERTING: pushes to HEALTHCHECK_URL (an Uptime Kuma push monitor) with an
# explicit up/down status, so a problem alerts immediately with the reason
# rather than waiting for a heartbeat to lapse. If this script stops running
# entirely, the heartbeat lapses and Kuma alerts anyway — both failure modes
# are covered. See docs/MONITORING.md.
#
# Exits non-zero when any device is WARN or FAIL, so a systemd timer or a
# manual run reports the problem through its own exit status too.

# NOT `set -e`: smartctl's exit status is a BITMASK (bit 3 = disk failing),
# so a non-zero exit is information to read, not a reason to abort.
set -uo pipefail

log()  { printf '[smart] %s\n' "$*"; }
warn() { printf '[smart] %s\n' "$*" >&2; }

FULL=0
case "${1:-}" in
	--full) FULL=1 ;;
	"")     ;;
	*)      warn "unknown argument: $1 (expected --full)"; exit 1 ;;
esac

# ─── Thresholds ──────────────────────────────────────────────────────────────
# Deliberately paranoid on the sector counts. On a modern drive the correct
# number of reallocated and pending sectors is ZERO; "a few" is not normal
# wear, it's the beginning of the end. Temperature and NVMe wear are the
# gradual ones and get real thresholds.
TEMP_WARN="${SMART_TEMP_WARN:-55}"              # °C
NVME_WEAR_WARN="${SMART_NVME_WEAR_WARN:-80}"    # % of rated endurance consumed
CRC_WARN="${SMART_CRC_WARN:-10}"                # UDMA CRC errors (cable/bridge, not platter)

REPORT_PATH="${SMART_REPORT_PATH:-/var/lib/smart/report.txt}"
HOSTNAME_LABEL="${SMART_HOST_LABEL:-$(hostname 2>/dev/null || echo unknown)}"

command -v smartctl >/dev/null 2>&1 || { warn "smartctl not found — install smartmontools"; exit 1; }
command -v jq       >/dev/null 2>&1 || { warn "jq not found — required to parse smartctl --json"; exit 1; }

# ─── Device discovery ────────────────────────────────────────────────────────
# SMART_DEVICES is a space-separated list of `path` or `path:type` entries, e.g.
#   SMART_DEVICES="/dev/sdb:sat /dev/nvme0"
# The `:type` is smartctl's -d flag. USB enclosures nearly always need `sat`
# (or `usbjmicron` for some JMicron bridges) because the USB-SATA bridge
# doesn't pass SMART through on its own. Left unset, we ask smartctl to scan —
# but scanning is exactly what tends to miss USB-attached drives, so pin them
# explicitly on any host where a USB enclosure holds real data.
declare -a DEVICES=()
if [[ -n "${SMART_DEVICES:-}" ]]; then
	read -r -a DEVICES <<<"$SMART_DEVICES"
else
	log "SMART_DEVICES unset — falling back to 'smartctl --scan'"
	while IFS= read -r line; do
		[[ -n "$line" ]] && DEVICES+=("$line")
	done < <(smartctl --scan --json 2>/dev/null \
		| jq -r '.devices[]? | "\(.name):\(.type)"' 2>/dev/null)
fi

if (( ${#DEVICES[@]} == 0 )); then
	warn "No devices to check. Set SMART_DEVICES explicitly (e.g. '/dev/sdb:sat')."
	warn "If this is the containerized runner, also confirm the container can"
	warn "actually reach block devices — see services/smart/docker-compose.yml."
	exit 1
fi

# ─── Per-device check ────────────────────────────────────────────────────────
declare -a FINDINGS=()   # "SEVERITY|device|message"
REPORT=""

emit() { REPORT+="$*"$'\n'; }

# jq helper: pull an ATA attribute's raw value by id, or empty if absent.
ata_attr() { jq -r --argjson id "$2" \
	'.ata_smart_attributes.table[]? | select(.id == $id) | .raw.value // empty' <<<"$1"; }

check_device() {
	local spec="$1" dev type json
	dev="${spec%%:*}"
	type="${spec#*:}"
	[[ "$type" == "$dev" ]] && type=""     # no ':type' given

	local -a args=(--json --info --health --attributes)
	(( FULL )) && args+=(--log=selftest)
	[[ -n "$type" ]] && args+=(-d "$type")

	json="$(smartctl "${args[@]}" "$dev" 2>/dev/null)"
	local rc=$?

	# Bit 1 (value 2) = device open failed. Everything else can still carry
	# usable data, so only treat "couldn't open it at all" as fatal here.
	if (( rc & 2 )) || [[ -z "$json" ]] || ! jq -e . >/dev/null 2>&1 <<<"$json"; then
		FINDINGS+=("FAIL|$dev|cannot read SMART data (smartctl rc=$rc)")
		emit "── $dev ── UNREADABLE"
		emit "   smartctl could not open the device (rc=$rc)."
		emit "   If this device is behind USB, try a -d type: '$dev:sat'."
		emit "   A device that was readable yesterday and is unreadable today is"
		emit "   itself a finding — the drive or its bridge may have dropped off."
		emit ""
		return
	fi

	local model serial capacity hours proto
	model="$(jq -r '.model_name // .scsi_model_name // "unknown"' <<<"$json")"
	serial="$(jq -r '.serial_number // "unknown"' <<<"$json")"
	capacity="$(jq -r '(.user_capacity.bytes // 0) | if . > 0 then (. / 1000000000000 * 100 | round / 100 | tostring)+" TB" else "unknown" end' <<<"$json")"
	hours="$(jq -r '.power_on_time.hours // "?"' <<<"$json")"
	proto="$(jq -r '.device.protocol // .device.type // "?"' <<<"$json")"

	emit "── $dev ── $model  (serial $serial, $capacity, $proto)"
	emit "   power-on hours: $hours"

	# Overall health verdict. When a drive says FAILED here, it is not a
	# warning — the drive's own firmware has concluded it is dying.
	local passed
	passed="$(jq -r '.smart_status.passed // empty' <<<"$json")"
	case "$passed" in
		true)  emit "   overall-health: PASSED" ;;
		false) emit "   overall-health: FAILED"
		       FINDINGS+=("FAIL|$dev|SMART overall-health FAILED — the drive's own firmware says it is failing ($model $serial)") ;;
		*)     emit "   overall-health: not reported" ;;
	esac

	# Temperature — both ATA and NVMe expose this in the same place in 7.x.
	local temp
	temp="$(jq -r '.temperature.current // empty' <<<"$json")"
	if [[ -n "$temp" ]]; then
		emit "   temperature: ${temp}°C"
		if (( temp >= TEMP_WARN )); then
			FINDINGS+=("WARN|$dev|temperature ${temp}°C at or above ${TEMP_WARN}°C — check enclosure airflow/fan")
		fi
	fi

	if [[ "$proto" == "NVMe" ]]; then
		local wear media_errors crit
		wear="$(jq -r '.nvme_smart_health_information_log.percentage_used // empty' <<<"$json")"
		media_errors="$(jq -r '.nvme_smart_health_information_log.media_errors // empty' <<<"$json")"
		crit="$(jq -r '.nvme_smart_health_information_log.critical_warning // empty' <<<"$json")"
		[[ -n "$wear"         ]] && emit "   endurance used: ${wear}%"
		[[ -n "$media_errors" ]] && emit "   media errors: $media_errors"
		[[ -n "$crit"         ]] && emit "   critical warning flags: $crit"
		[[ -n "$wear"         ]] && (( wear >= NVME_WEAR_WARN )) && \
			FINDINGS+=("WARN|$dev|NVMe endurance ${wear}% consumed (threshold ${NVME_WEAR_WARN}%) — plan a replacement")
		[[ -n "$media_errors" ]] && (( media_errors > 0 )) && \
			FINDINGS+=("WARN|$dev|NVMe reports $media_errors media error(s) — unrecoverable read/write events")
		[[ -n "$crit"         ]] && (( crit != 0 )) && \
			FINDINGS+=("FAIL|$dev|NVMe critical warning flags set (0x$(printf '%x' "$crit"))")
	else
		# ATA/SATA. These four are the ones that actually predict failure.
		local realloc pending offline crc
		realloc="$(ata_attr "$json" 5)"     # Reallocated_Sector_Ct
		pending="$(ata_attr "$json" 197)"   # Current_Pending_Sector
		offline="$(ata_attr "$json" 198)"   # Offline_Uncorrectable
		crc="$(ata_attr "$json" 199)"       # UDMA_CRC_Error_Count
		emit "   reallocated: ${realloc:-n/a}   pending: ${pending:-n/a}   offline-uncorrectable: ${offline:-n/a}   crc: ${crc:-n/a}"

		[[ -n "$realloc" ]] && (( realloc > 0 )) && \
			FINDINGS+=("WARN|$dev|$realloc reallocated sector(s) — the correct number is zero; this drive has started remapping bad blocks")
		[[ -n "$pending" ]] && (( pending > 0 )) && \
			FINDINGS+=("FAIL|$dev|$pending pending sector(s) — the single strongest predictor of imminent failure; replace this drive")
		[[ -n "$offline" ]] && (( offline > 0 )) && \
			FINDINGS+=("WARN|$dev|$offline offline-uncorrectable sector(s) — data in those sectors is already unreadable")
		# CRC errors are the cable/bridge, not the platter. Worth flagging (a
		# flaky USB link corrupts writes) but not "replace the drive".
		[[ -n "$crc" ]] && (( crc >= CRC_WARN )) && \
			FINDINGS+=("WARN|$dev|$crc UDMA CRC error(s) — this is the CABLE or USB bridge, not the platter; reseat/replace the cable")
	fi

	if (( FULL )); then
		emit ""
		emit "   --- full attribute table ---"
		while IFS= read -r l; do emit "   $l"; done < <(
			jq -r '.ata_smart_attributes.table[]? |
			       "\(.id)\t\(.name)\traw=\(.raw.string)\tnorm=\(.value)\tthresh=\(.thresh)"' <<<"$json" 2>/dev/null
		)
		local st
		st="$(jq -r '.ata_smart_self_test_log.standard.table[]? |
		             "   selftest #\(.type.string) status=\(.status.string) hours=\(.lifetime_hours)"' <<<"$json" 2>/dev/null)"
		[[ -n "$st" ]] && { emit ""; emit "   --- recent self-tests ---"; while IFS= read -r l; do emit "$l"; done <<<"$st"; }
	fi
	emit ""
}

emit "CoralStack SMART report — ${HOSTNAME_LABEL} — $(date '+%Y-%m-%dT%H:%M:%S%z')"
emit ""
for spec in "${DEVICES[@]}"; do
	check_device "$spec"
done

# ─── Verdict ─────────────────────────────────────────────────────────────────
STATUS=OK
for f in "${FINDINGS[@]:-}"; do
	[[ -z "$f" ]] && continue
	case "${f%%|*}" in
		FAIL) STATUS=FAIL ;;
		WARN) [[ "$STATUS" == OK ]] && STATUS=WARN ;;
	esac
done

n_fail=0 n_warn=0 worst=""
for f in "${FINDINGS[@]:-}"; do
	[[ -z "$f" ]] && continue
	case "${f%%|*}" in
		FAIL) (( n_fail++ )); [[ -z "$worst" || "$worst" != FAIL* ]] && worst="$f" ;;
		WARN) (( n_warn++ )); [[ -z "$worst" ]] && worst="$f" ;;
	esac
done

# The alert lands on a phone. Lead with the verdict and ONE concrete finding —
# the full detail is in the report file and the container logs.
SUMMARY="${HOSTNAME_LABEL}: ${#DEVICES[@]} device(s) — $STATUS"
if (( ${#FINDINGS[@]} )); then
	emit "── findings ──"
	for f in "${FINDINGS[@]}"; do
		[[ -z "$f" ]] && continue
		emit "   [${f%%|*}] $(cut -d'|' -f2- <<<"$f" | tr '|' ' ')"
	done
	emit ""
	emit "Next step: docs/HARDWARE_FAILURE.md → 'A drive is reporting SMART errors'"
	SUMMARY+=" (${n_fail} fail, ${n_warn} warn)"
	[[ -n "$worst" ]] && SUMMARY+=" — $(cut -d'|' -f2- <<<"$worst" | tr '|' ' ')"
fi

printf '%s' "$REPORT"

# Persist the latest report so it can be read after the fact — during an
# incident, `docker logs` may be the thing you cannot get to.
if mkdir -p "$(dirname "$REPORT_PATH")" 2>/dev/null; then
	printf '%s' "$REPORT" >"$REPORT_PATH" 2>/dev/null \
		|| warn "could not write report to $REPORT_PATH"
else
	warn "could not create $(dirname "$REPORT_PATH") — skipping report file"
fi

# ─── Push to the monitor ─────────────────────────────────────────────────────
# Explicit up/down so a finding alerts NOW. Kuma caps msg length; keep it tight.
if [[ -n "${HEALTHCHECK_URL:-}" ]]; then
	push_status=up
	[[ "$STATUS" == OK ]] || push_status=down
	if curl -fsS -m 10 --retry 3 -G "$HEALTHCHECK_URL" \
		--data-urlencode "status=$push_status" \
		--data-urlencode "msg=${SUMMARY:0:400}" >/dev/null 2>&1; then
		log "pushed status=$push_status to healthcheck"
	else
		warn "healthcheck push failed (the SMART check itself completed: $STATUS)"
	fi
fi

log "$SUMMARY"
[[ "$STATUS" == OK ]] || exit 1
exit 0
