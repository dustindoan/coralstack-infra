# Storage array: failure modes, guards, and recovery

`/mnt/storage` is a TerraMaster D-series DAS (8TB, ext4, label `coralstack`)
attached over USB and passed through to the `apps` VM (Proxmox VMID 101) as
`usb0: host=174c:235c` -- bound by vendor:product, so it survives re-plugging
into a different port.

Everything in `services/` that references `${STORAGE_PATH}` depends on it:
`arr`, `backup`, `ente`, `jellyfin`, `music`, `samba-staging`.

## The two failure modes

### 1. The array drops off the bus

Observed 2026-08-28 14:13 PDT. The device stopped responding
(`hostbyte=DID_NO_CONNECT`), ext4 failed to write its journal and superblock,
and the block device disappeared from `lsblk` entirely. Jellyfin returned
HTTP 500 on every media request (`FFmpeg exited with code 251`,
`Input/output error` on cover art) while the API kept serving 200s, because
Jellyfin`s database lives on the VM`s own disk, not on the array.

It did not come back from: re-seating the USB cable, power-cycling the VM, or
power-cycling the NUC. It came back only after power-cycling the TerraMaster
enclosure itself.

**Contributing factor -- not yet fixed.** The array negotiates a **USB 2.0
(480 Mbps) link**, behind the enclosure`s internal `4-Port USB 2.0 Hub`, while
the NUC`s SuperSpeed bus (Bus 002, 5000M) sits empty:

```
Bus 001 (480M) - Port 003: TerraMaster 4-Port USB 2.0 Hub
                   - Port 001: TDAS Mass Storage, 480M   <- the array
Bus 002 (5000M SuperSpeed) - empty
```

That 480 Mbps link was **deliberate**, not an accident: the array had
previously been on USB 3 and would drop intermittently and not come back, so it
was moved down to USB 2.0 as a mitigation. The journal shows that trade worked
-- see "USB link history" below. It capped throughput at roughly 40 MB/s, and
it did not make the array immune: 2026-08-28 was a drop on the 2.0 link.

As a software mitigation, UAS is disabled for this specific device via
`usb-storage.quirks=174c:235c:u` on the `apps` VM kernel cmdline. UAS on a
2.0 link with an ASMedia bridge is the unstable combination; plain
`usb-storage` (bulk-only) is slower but markedly more reliable.

### 2. Containers start before the mount -- the silent one

This is what turned a recoverable outage into hours of misdiagnosis.

A bind mount resolves **once**, at container start, and never re-resolves. All
25 services run `restart: unless-stopped`, so dockerd recreates them the moment
it starts -- with no ordering against `mnt-storage.mount`, which is gated on a
USB device that takes ~50s to enumerate after a power cycle.

On the 2026-08-28 reboot dockerd won by **nine seconds**:

```
jellyfin   started 22:16:42.83
sdb mounted        22:16:52
```

Every storage-backed container was pinned to an empty directory on the root
filesystem for its whole lifetime. The host saw 134 artist directories;
Jellyfin saw none -- and reported `healthy` throughout, because the stock
healthcheck only probes the HTTP port.

## The guards now in place

1. **`x-systemd.device-timeout=90` in `/etc/fstab`** -- systemd waits up to 90s
   for the enclosure to enumerate instead of giving up immediately. `nofail`
   stays, so the box always boots and you keep SSH and Caddy with a dead disk.

2. **`host/docker-wait-for-storage.conf`** -> installed as
   `/etc/systemd/system/docker.service.d/wait-for-storage.conf`. Orders dockerd
   after `mnt-storage.mount`. Uses `Wants=`, not `Requires=`: Docker waits for
   the mount attempt to settle, then starts either way. A dead disk must not
   take down the services you need in order to fix it. This covers all 25
   containers and every future one -- there is no per-service list to maintain.

3. **`/mnt/storage/.coralstack-mounted`** -- a sentinel file living on the ext4
   filesystem itself. Ordering guarantees say nothing about *contents*: a bare
   directory or a blank replacement disk both look like a successful mount.
   `test -f` on this file is the only check that distinguishes the real array.

4. **Data-aware healthcheck on Jellyfin** -- verifies `/media/music` is
   non-empty as well as that the port answers, so an empty library shows as
   `unhealthy` in `docker ps` and on the homepage dashboard instead of passing
   silently.

Note: `chmod 000` on `/mnt/storage` is NOT a guard. dockerd runs as root and
root bypasses mode bits; only 172K of stray writes landed there on 2026-08-28
because little had started yet, not because permissions stopped anything.

## Recovery procedure

1. Confirm what is actually wrong:
   ```
   ssh coralstack-apps "lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT; findmnt /mnt/storage"
   ssh proxmox "lsusb -t"
   ```
2. If the device is absent from the guest, check whether the **host** sees it
   (`ssh proxmox lsusb | grep 174c`). If the host cannot see it either, the fix
   is physical -- power-cycle the TerraMaster enclosure. Re-seating the cable,
   rebooting the VM, and rebooting the NUC have all been tried and do not work.
3. Once the device is back, check the filesystem **before** anything writes:
   ```
   ssh coralstack-apps "dumpe2fs -h /dev/sdb | grep -iE \"state|error\""
   ```
   `needs_recovery` in the feature list is normal while mounted -- it is set at
   mount and cleared on clean unmount. It is not a fault indicator.
4. Verify containers actually see the data, not just that they are running:
   ```
   ssh coralstack-apps "docker exec jellyfin ls /media/music/Music | wc -l"
   ```
   Zero here with a healthy host mount means containers lost the ordering race
   and need `docker compose up -d --force-recreate` for the affected services.

## Verifying the guards after a reboot

```
ssh coralstack-apps "systemctl show docker.service -p After | tr \",\" \"\\n\" | grep mnt-storage"
ssh coralstack-apps "test -f /mnt/storage/.coralstack-mounted && echo sentinel OK"
ssh coralstack-apps "docker ps --filter name=jellyfin --format \"{{.Status}}\""
ssh coralstack-apps "cat /proc/cmdline | grep -o \"usb-storage.quirks=[^ ]*\""
```

## Gotcha: compose edits are not deployed by a reboot

`restart: unless-stopped` restarts the **existing container definition**. It does
not re-read `docker-compose.yml`. A reboot therefore brings back the *old*
config, and `docker ps` will happily report `healthy` using the *old*
healthcheck. After changing any compose file you must explicitly run:

```
docker compose up -d <service>     # recreates with the new definition
```

Verify what is actually deployed rather than what is committed:

```
docker inspect jellyfin --format "{{json .Config.Healthcheck.Test}}"
```

This bit during the 2026-08-28 recovery: the data-aware healthcheck was
committed and the container reported healthy for several minutes, but the
deployed check was still the stock HTTP-only one.

## USB link history, and why we are on USB 3 again

The array had been moved to a USB 2.0 cable deliberately, because on USB 3 it
would drop intermittently and not return. The host journal (persistent, back to
May 2026) shows that mitigation genuinely worked:

```
boot -4, 2026-06-23 -> 2026-08-28 (66 days, USB 2.0):
  array (174c:235c) enumerations: 1 on 2026-06-23, none until 2026-08-28
  USB disconnect/reset events:    1 on 2026-06-23, then 111 -- all on 2026-08-28
```

Sixty-six days with a single clean enumeration and no drops. Every error in that
window belongs to the 2026-08-28 failure and the power-cycling that followed.
USB 2.0 was not immunity, but it was materially stable.

We are back on USB 3 (10 Gbps, SuperSpeed Plus Gen 2x1) because **two causes
that were present during the earlier USB 3 trials have since been removed**:

1. **UAS.** Disabled for this device via `usb-storage.quirks=174c:235c:u`. The
   `uas_zap_pending` / `DID_NO_CONNECT` signature in the 2026-08-28 logs is the
   textbook ASMedia UAS failure, and disabling UAS is the standard remedy for
   "drops and does not come back". The earlier USB 3 attempts ran with UAS on.
2. **Hub autosuspend.** Both enclosure hubs shipped with `power/control=auto`
   and `autosuspend_delay_ms=0`. Now pinned to `on` by
   `host/proxmox/99-coralstack-storage.rules`.

Neither had been addressed before, so USB 3 today is not the configuration that
failed previously. This is a reasoned bet, not a guarantee.

### Decision rule

**One unexplained drop within 14 days of 2026-08-28 and we revert to USB 2.0**,
keeping both mitigations (a combination never yet tried). Do not spend a second
evening re-diagnosing this: the forensics will already be captured.

### Revert procedure

1. Swap back to the USB 2.0 cable, or move to a non-SuperSpeed port.
2. Confirm the downgrade: `ssh proxmox "lsusb -t | grep -i mass"` should show
   `480M` rather than `10000M`.
3. Nothing else changes. The quirk, the udev rules, the mount ordering, the
   sentinel and the healthcheck are all link-speed independent.

### Where the evidence lands next time

A drop now fires `/usr/local/bin/coralstack-usb-drop-capture` via udev, writing
`lsusb -t`, the enclosure power state, and 300 lines of kernel log to
`/var/log/coralstack-usb-drops/drop-<timestamp>.log` on the Proxmox host, plus a
syslog line tagged `coralstack-usb`. Check there first.
