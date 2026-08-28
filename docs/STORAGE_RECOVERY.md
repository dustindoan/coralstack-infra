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

An 8TB spinning array on a 480 Mbps link through a hub, driven by an ASMedia
bridge under UAS, is a well-known dropout profile -- and it caps throughput at
roughly 40 MB/s. **Fix the physical link first:** use a USB 3 cable into a
SuperSpeed port on the NUC and confirm the device lands on Bus 002 at 5000M.
Everything below only limits the blast radius; it does not stop the drop.

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
