# Hardware failure

A piece of hardware has died or is dying. This is how to work out **which**
piece, what it took with it, and how to get back.

> **This is not [RECOVERY.md](RECOVERY.md).** That runbook covers *power loss* —
> the hardware is fine and the question is whether everything auto-started. Its
> entire failure model is "did the box come back up." This document covers the
> case where it doesn't come back up, or comes back wrong, because a component
> is broken.

It is also the thing [coralstack.org](SITE_COPY.md) is pointing at when it
answers *"What happens if the hardware dies? Backups + a documented rebuild
procedure. The recovery runbooks are public in the repo — judge them
yourself."* That claim should stay honest, so keep this current.

---

## Part 0 — Do this before you need it

Under pressure you will not be able to work out which physical drive to pull.
Fill this in **now**, and re-verify after any hardware change.

### Hardware inventory

Fill from the box; don't fill from memory. Serial numbers are how you match a
SMART finding (which names a serial) to a physical object (which is in a bay).

```bash
# On the Proxmox host and on the apps VM:
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL
smartctl --scan
```

| Slot / role | Device | Model | Serial | Capacity | Purchased | Warranty ends |
| ----------- | ------ | ----- | ------ | -------- | --------- | ------------- |
| NUC internal SSD (SATA, **not** M.2) | `/dev/sda` | SanDisk SDSSDA240G | `171015446910` | 240 GB | | |
| TerraMaster bay 1 | `/dev/sdb` | Seagate ST8000DM004-2U9188 | `ZR16GZ2M` | 8 TB | | |
| TerraMaster bay 2 | *(empty)* | — | — | — | — | — |
| TerraMaster bay 3 | *(empty)* | — | — | — | — | — |
| TerraMaster bay 4 | *(empty)* | — | — | — | — | — |

| Box | Model | Role | Address | Notes |
| --- | ----- | ---- | ------- | ----- |
| NUC | NUC7 (Iris 650) | Proxmox host; runs OPNsense VM + apps VM | `192.168.4.10` mgmt, `192.168.4.20` OPNsense WAN | |
| TerraMaster | D4-320 | USB-C DAS, passed through to apps VM | `/mnt/storage` | ASMedia ASM235CM bridge (`174c:235c`), `-d sat`; 1 of 4 bays populated |
| Mac mini | | Ollama inference | `10.0.1.10` (OPT1/VLAN 10) | |
| eero | | Home router / WAN path | `192.168.4.1` | Consumer gear, no API |

> **Also write down which physical bay is which `/dev/sdX`.** Label the bays
> with tape. Enclosure bay order and kernel device order are not guaranteed to
> match, and getting this wrong means pulling a healthy drive out of a degraded
> array — which is how a recoverable incident becomes a data-loss incident.

### The one thing to verify right now

**Which physical disk is `DATA_PATH` on?** This determines the blast radius of
every failure below, and it is currently ambiguous in the docs.

`DATA_PATH` holds Vaultwarden's database, Pocket ID's database, Ente's
Postgres, and every service's config. `STORAGE_PATH` (`/mnt/storage`, the
TerraMaster) holds the Ente photo blobs and the media libraries. The default in
`.env.example` is `./data` — repo-relative, which puts it on the apps VM's
100 GB virtual disk, i.e. **on the NUC's M.2**, not on the TerraMaster.
[PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) says of that VM disk "data lives
on TerraMaster," which describes the intent for bulk data but not necessarily
where `DATA_PATH` actually resolved on this box.

Settle it and record the answer here:

```bash
# On the apps VM, from the repo checkout:
grep '^DATA_PATH=' .env
df -h "$(grep '^DATA_PATH=' .env | cut -d= -f2)"   # which filesystem is it on?
```

**Answer for this deployment:** _(fill in — `/dev/…`, on the M.2 / on the TerraMaster)_

If it's on the M.2: that single non-redundant SSD holds the identity provider,
the password manager, and the photo *metadata*, and an M.2 failure is a full
rebuild. That's survivable (it's all in the nightly backup) but it's the
highest-consequence disk in the building, and it's worth knowing that before
the day it matters.

---

## Part 1 — Failure domains

What dies with what. Read this as "if X fails, everything in the second column
is down until X is replaced."

| If this fails | What goes down | What survives | Recoverable from | Realistic time |
| ------------- | -------------- | ------------- | ---------------- | -------------- |
| **TerraMaster drive** (`/dev/sdb`) | Photos, music, TV/movies | Identity, vaults, all service configs (if `DATA_PATH` is on the M.2) | Photo blobs from B2. **Music and media are NOT backed up** — see below | Half a day + restore time over your uplink |
| **TerraMaster enclosure** (bridge/PSU, drive fine) | Same as above | The drive itself and its data | Move the drive to another enclosure or attach it directly | Hours, once you have an enclosure |
| **NUC M.2 SSD** | *Everything.* Proxmox, OPNsense, the apps VM | TerraMaster data (untouched, external) | Full rebuild + restic restore | **1-2 days** |
| **NUC itself** (board/PSU/RAM) | Everything | Both disks — pull the M.2 and the DAS | New host, move the M.2 across, or rebuild | Hours if you have a spare box; days if you're buying one |
| **Mac mini** | AI chat only | Everything else | Graceful degradation — nothing else depends on it | Whenever you feel like it |
| **eero** | Internet in and out, family WiFi | The stack itself keeps running internally | Replace router, re-add the port-forward + DHCP reservation | Hours, plus a trip to a store |

The Mac mini row is the one piece of good architectural news: it is the only
component whose failure is a feature degradation rather than an outage.

---

## Part 2 — First response

**Before assuming hardware, rule out the cheap explanations.** Most "everything
is down" turns out to be one container, DNS, or the ISP.

```bash
# 1. Is it actually the stack, or the path to it? Test from OUTSIDE the
#    failure domain — LTE tethering, not home WiFi.
curl -sS -o /dev/null -w '%{http_code}\n' https://id.<BASE_DOMAIN>

# 2. Layer by layer, from the outside in:
ping -c2 192.168.4.1     # eero
ping -c2 192.168.4.10    # Proxmox host
ping -c2 10.0.0.1        # OPNsense LAN
ping -c2 10.0.0.10       # apps VM

# 3. On the apps VM — is it one service or all of them?
docker ps -a --format 'table {{.Names}}\t{{.Status}}'
df -h                    # a full disk looks exactly like a broken one
```

The first of those pings to fail tells you which layer to look at. If they all
succeed and services are still broken, it is **not** a hardware problem —
go to [RECOVERY.md](RECOVERY.md)'s per-service smoke checks instead.

### Is it the disk? The three questions

```bash
# 1. Is the kernel logging I/O errors? This is the loudest possible signal.
dmesg -T | grep -iE 'i/o error|ata[0-9]|nvme|reset|failed command|medium error' | tail -40

# 2. What does the drive say about itself?
smartctl -a -d sat /dev/sdb        # TerraMaster, from the APPS VM
smartctl -a /dev/nvme0             # M.2, from the PROXMOX HOST

# 3. Is the filesystem still actually mounted?
mountpoint /mnt/storage && ls /mnt/storage
```

That third one matters more than it looks. Mount points in this stack are
deliberately **fail-closed** — the bare directory is `chmod 000` so that if the
USB device drops off, writes fail loudly instead of silently filling the VM's
root disk. So the symptom of "the TerraMaster fell off the bus" is *permission
denied*, not *file not found*. Don't chase a permissions bug that is really a
disconnected disk.

---

## Part 3 — Runbooks by failure

### A drive is reporting SMART errors

This is where a `status=down` alert from the SMART monitor lands you. The drive
still works. You have time — use it.

**Triage by what's reported:**

| Finding | Meaning | Action |
| ------- | ------- | ------ |
| `pending sectors > 0` | Sectors the drive cannot read and has not yet remapped. The strongest predictor of imminent failure. | **Replace the drive.** Don't wait for it to get worse. |
| `overall-health FAILED` | The drive's own firmware has concluded it is dying | **Replace the drive**, today |
| `reallocated sectors > 0` | Bad blocks already remapped. Zero is the correct number. | If it's stable at a small number, watch weekly. If it's climbing, replace. |
| `offline uncorrectable > 0` | Data in those sectors is already unreadable | Verify backups cover it, then replace |
| `UDMA CRC errors` climbing | **The cable or USB bridge, not the platter** | Reseat or replace the cable first. Don't replace a healthy drive over this. |
| `temperature` high | Airflow, ambient, or a failed fan | Check the enclosure fan before anything else |
| NVMe `endurance > 80%` | Write wear, gradual and predictable | Budget for a replacement; not urgent |

**Before replacing anything:**

```bash
# 1. Confirm the backup is current and complete — do not skip this.
docker exec backup restic snapshots --tag data    | tail -5
docker exec backup restic snapshots --tag storage | tail -5

# 2. Verify the repo is actually readable, not just present.
docker exec backup restic check

# 3. Physically identify the drive by SERIAL, not by bay position.
smartctl -i -d sat /dev/sdb | grep -i serial
```

Match that serial against the inventory table in Part 0. **Pull the drive whose
serial matches — never the one you assume is in that bay.**

### The TerraMaster drive died

Everything on `/mnt/storage` is gone: Ente photo blobs, music, TV/movies.

1. Replace the drive. Partition, `mkfs.ext4`, and mount it at `/mnt/storage`
   with the same `chmod 000`-on-the-bare-mountpoint fail-closed setup
   ([PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) Phase 4c).
2. Restore the photo blobs from the `storage` stream:
   ```bash
   docker exec backup restic restore latest --tag storage --target /
   ```
   Restore procedure and gotchas: [BACKUPS.md](BACKUPS.md#restore).
3. **Music and video do not come back.** They're excluded from backup by
   design as re-acquirable (see below). Re-rip, re-download, re-acquire.
4. Bring Ente back up and confirm the photo library loads on a client — the
   blobs and the Postgres metadata have to agree, and Postgres lives in
   `DATA_PATH`, which may have survived independently.

> **While you're in there:** this is the natural moment to populate the other
> three bays and build the mdadm RAID 6 that's been a deferred followup since
> the migration. You already have the enclosure open, the data is already
> restored from backup, and a rebuild is exactly the cost you just paid.

### The NUC's M.2 SSD died

The big one. Proxmox, OPNsense's virtual disk, the apps VM's virtual disk, and
(probably — see Part 0) `DATA_PATH` were all on it. Go to Part 4.

### The NUC itself died

If the M.2 is fine, the fastest path is a transplant rather than a rebuild:

1. Pull the M.2. Get a replacement host — any x86 box with an M.2 slot will
   boot Proxmox off it.
2. **Expect the NIC name to change** (`enp0s31f6` → something else). Proxmox's
   `/etc/network/interfaces` and the OPNsense VM's interface assignments are
   pinned to names and MACs that no longer exist. Fix at the console:
   - Proxmox: edit `/etc/network/interfaces`, match the new interface name.
   - OPNsense: console option **1) Assign interfaces**, re-map WAN/LAN/OPT1.
3. Re-add the eero DHCP reservation for the new WAN-side MAC, and re-point the
   443 port-forward at it. eero has no API — this is manual, in the app.
4. Re-attach the TerraMaster and re-add the USB passthrough to the apps VM
   (`qm set 101 -usb0 host=<vendor:product>`).

If the M.2 is *not* fine, that's the full rebuild in Part 4.

### The Mac mini died

Open WebUI's chat stops working. Nothing else is affected — no service takes a
hard dependency on it. Fix it whenever convenient; there's no incident here.

Confirm that's all it is:

```bash
curl -fsS http://10.0.1.10:11434/api/tags   # from the apps VM
```

If that fails but the Mac mini is up, it's more likely the OPT1/VLAN path or
the Ollama LaunchAgent than dead hardware — see [RECOVERY.md](RECOVERY.md).

### eero died

The stack keeps running; nothing can reach it, including from inside the house.
Replace the router, then restore the two settings that CoralStack depends on:

- A **DHCP reservation** pinning the NUC's WAN-side MAC to `192.168.4.20`.
- A **port-forward** of 443 (TCP **and UDP**, for HTTP/3) to that address.

Both are documented as permanently-manual steps — consumer router, no API.

---

## Part 4 — Rebuild from nothing

The NUC's system disk is gone. This is the procedure the public site promises
exists.

### What you need in hand before you start

Check you have these **before** you begin, not partway through:

| Thing | Where it should be | If you don't have it |
| ----- | ------------------ | -------------------- |
| `RESTIC_PASSWORD` | **Tier 1: paper, in the safe** | **The backups are unrecoverable.** There is no reset. |
| B2 (or other remote) credentials | Tier 1 | Can't reach the repo |
| Cloudflare API token | Tier 1 | No TLS certs; can re-create from the Cloudflare dashboard |
| Proxmox / OPNsense root passwords | Tier 1 | Reinstalling anyway, so survivable |
| A Proxmox installer USB | Physical | Download it — needs a working machine |

> **The circularity to understand:** most service secrets live in Vaultwarden
> (Tier 2) — and Vaultwarden is one of the services that is down. That's why
> the backup deliberately captures `/config` including the gitignored
> `services/*/.env` files, and why `RESTIC_PASSWORD` **must** be Tier 1 on
> paper. The restic password is the one secret that cannot live in the system
> it protects. Verify it's actually in the safe, and that it's the *current*
> one, before you ever need this page.

### Order of operations

Roughly a day of work, most of it waiting on downloads and restores.

1. **Reinstall Proxmox** on the new system disk —
   [PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) Phase 1. Same management IP
   (`192.168.4.10`) so nothing downstream needs re-pointing.
2. **Rebuild the OPNsense VM** — Phase 3. Then **Restore the config**:
   Diagnostics → Backup/Restore → upload the `config.xml` export from Tier 1
   storage. This is minutes instead of hours, and is the entire reason that
   export is a documented habit. *(If you don't have a recent `config.xml`,
   you're re-doing interfaces, NAT, firewall rules, Kea, and Unbound by hand
   from Phase 3 — budget several hours and expect to miss something.)*
3. **Rebuild the apps VM** — Phase 4. Ubuntu Server LTS, Docker, re-add the
   TerraMaster USB passthrough, re-mount `/mnt/storage` fail-closed.
4. **Clone the repo** and restore the `data` stream:
   ```bash
   git clone https://github.com/dustindoan/coralstack-infra.git
   # restic restore of /config first — it carries the services/*/.env secrets
   # that setup.sh would otherwise regenerate as NEW values, which would
   # orphan every existing database. See BACKUPS.md.
   ```
   Full procedure: [BACKUPS.md → Disaster recovery](BACKUPS.md#disaster-recovery-host-is-gone).
5. **Restore the databases from the dumps in `/staging`**, not from the
   copied database directories — the dumps are the authoritative, consistent
   source. Ente via `pg_restore`, Vaultwarden and Pocket ID SQLite by file.
6. **Bring the stack up**, then walk [RECOVERY.md](RECOVERY.md)'s per-service
   smoke checks. Containers running is not the same as services working.
7. **Re-verify from off-net** (LTE), not from inside the house.

### Do not run `setup.sh` over a restored `/config`

`setup.sh` generates secrets when it finds empty values. If it runs before the
`.env` files are restored, it will mint **new** database passwords, encryption
keys, and JWT secrets — which will not match the databases you're restoring,
and Ente in particular will not decrypt. Restore first, then only run
`setup.sh` if something is genuinely missing.

---

## Part 5 — What you cannot get back

Say this out loud once so it isn't a discovery during an incident.

- **Music library** and **TV/movies** (`/storage/music`, `/storage/media`) are
  excluded from backup by design — large, and re-acquirable. A TerraMaster
  failure loses them permanently. That is a deliberate trade (see
  [BACKUPS.md](BACKUPS.md#whats-backed-up--and-what-isnt)); the knob to change
  it is `BACKUP_EXCLUDES`, and the cost is pushing TBs to metered cloud.
- **Anything since the last nightly run.** The backup is at 03:15. Worst case
  is ~24 hours of photos.
- **Uptime Kuma's monitor configuration**, but only if the restore itself
  fails — the nightly backup dumps its SQLite DB explicitly, so a normal
  restore brings it back. Worth knowing it has no config-as-code path, so if
  the dump were ever missing, rebuilding means re-walking
  [MONITORING.md](MONITORING.md)'s checklist by hand.
- **Anything a member deleted more than the retention window ago.** Retention
  is 7 daily / 4 weekly / 6 monthly on `data`, 7/4/0 on `storage`.

---

## Part 6 — Known single points of failure

An honest list. None of these is currently mitigated by redundancy; all of them
are mitigated by backups, which means the failure mode is *downtime*, not *data
loss*.

| SPOF | Consequence | What would fix it | Status |
| ---- | ----------- | ----------------- | ------ |
| **NUC M.2 SSD** — no redundancy, ext4 | Total outage, 1-2 day rebuild | A second M.2 + ZFS mirror, or `local-lvm` on a mirror | Not planned. Would need a second M.2 slot |
| **TerraMaster: 1 drive of 4 bays** | Photo/media outage; blobs restore from B2 | Populate bays + mdadm RAID 6 | Deferred followup — trigger was "when data stops being expendable", which has arguably passed |
| **The NUC is everything** | One box runs firewall, identity, photos, media | A second host | Phase 3 concern |
| **eero is the only WAN path** | No external access | Second WAN / LTE failover | Out of scope for Phase 1 |
| **No UPS** | Every power blip is an unclean shutdown for a live Postgres | A UPS with USB signalling + NUT | Not planned. `RECOVERY.md` handles the boot side but not the corruption risk |
| **Monitoring lives on the monitored host** | If the NUC dies, no alert fires | One external check | See [MONITORING.md](MONITORING.md#what-is-still-not-covered) |

> **RAID is not backup, and backup is not availability.** The backups are real
> and restore-tested, so the *data* is safe. What none of this buys is staying
> up — every row above means an outage measured in hours or days. For a
> single-household trial that's an acceptable trade. Before a second household
> depends on this, the RAID 6 row and the UPS row deserve a real decision
> rather than a deferral.

---

## When to re-read this

- **After any SMART alert** — that's what it's for.
- **After any hardware change** — update the Part 0 inventory the same day.
- **Before onboarding household 2** — the last moment the SPOF table is a
  private trade-off rather than something other families are exposed to.
- **Annually**, alongside the [RECOVERY.md](RECOVERY.md) power-loss test.
