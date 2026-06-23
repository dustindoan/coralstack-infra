# GPU transcoding (Jellyfin hardware acceleration)

Offload Jellyfin transcoding from the CPU to the NUC's Intel iGPU (Quick Sync).
Without this, Jellyfin software-transcodes on the 2-core i7-7567U (`libx264`),
which caps how many simultaneous streams — Live TV included — the host can serve
and burns CPU/power doing it.

> **Status: DONE on this NUC (2026-06-23).** iGPU is passed through to apps VM 101 and
> Jellyfin has `/dev/dri`. The steps below are the as-executed runbook (re-run if the VM
> is rebuilt). Part 1 is host-admin **boundary work** needing a maintenance window (host +
> VM reboot = full-stack downtime). The only remaining manual step is #9 (enable QSV in
> the Jellyfin UI), unless `encoding.xml` gets templated later.

## Hardware (this deployment)

| | |
| --- | --- |
| CPU / iGPU | Intel **i7-7567U** (Kaby Lake) / **Iris Plus Graphics 650** (`8086:5927`) |
| Quick Sync caps | H.264 + HEVC 8-bit encode/decode; HEVC 10-bit + VP9 decode |
| Apps VM | Proxmox **VMID 101** (`apps`), KVM (not LXC) |
| IOMMU | Active (12 groups); iGPU **alone in IOMMU group 0** — clean passthrough, no ACS override |
| Host | Proxmox 9.1.8, kernel 6.17, EFI/GRUB boot; VT-d enabled in BIOS |

Because the apps box is a **KVM VM**, the iGPU must be **passed through via VFIO** — a
container-style `/dev/dri` bind-mount isn't available. GVT-g (mediated/shared vGPU) is
removed from modern kernels, so this is full, exclusive passthrough to VM 101.

**Trade-off (decision):** the host gives up its only GPU and loses console video
output. It's already headless (SSH + Proxmox web), so this is acceptable. The Mac mini
runs AI inference, so nothing else needs the iGPU. Alternative considered — splitting
Jellyfin into its own LXC that shares the host `/dev/dri` (no VFIO, host keeps the GPU)
— rejected: it breaks the single composed-stack model and Caddy wiring.

---

## Part 1 — Proxmox host: VFIO passthrough (boundary work, maintenance window)

Run on the Proxmox host (`coralstack-nuc`). **Schedule downtime** — step 5 reboots the
host, taking the whole stack offline for a few minutes.

1. **(Optional) make IOMMU explicit.** IOMMU is already active, but pinning it is
   belt-and-suspenders. Add to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`:
   ```
   intel_iommu=on iommu=pt
   ```
   then `update-grub`.

2. **Bind the iGPU to vfio-pci instead of i915.** Create `/etc/modprobe.d/vfio.conf`:
   ```
   options vfio-pci ids=8086:5927
   softdep i915 pre: vfio-pci
   ```
   And ensure vfio loads early — add to **both** `/etc/modules` *and*
   `/etc/initramfs-tools/modules` (the latter is what actually put vfio-pci in the
   initramfs so it claims the GPU before i915 — `/etc/modules` alone wasn't enough here):
   ```
   vfio
   vfio_iommu_type1
   vfio_pci
   ```
   Then `update-initramfs -u -k all`. Verify with
   `lsinitramfs /boot/initrd.img-$(uname -r) | grep vfio-pci.ko`.

3. **Assign the device to VM 101** — **without** `pcie=1`:
   ```
   qm set 101 -hostpci0 0000:00:02.0
   ```
   ⚠️ The "textbook" form `...,pcie=1` **fails** here (`q35 machine model is not enabled`):
   PCIe passthrough needs the `q35` machine type, but VM 101 is `i440fx`, and converting
   a running production VM to q35 risks renaming the guest NIC (→ broken networking, and
   with the iGPU now passed through the host has no console for recovery). Legacy PCI
   passthrough on i440fx works fine for a render-only iGPU, so we keep i440fx and omit
   `pcie=1`. (If you ever do want q35, do it in a window where you can reach the guest via
   the Proxmox **noVNC** console — that still works, the VM keeps its emulated VGA.)

4. **Stop VM 101** (`qm stop 101`) so it restarts cleanly with the new device.

5. **Reboot the host** (`reboot`). It comes back **headless** (no console video — SSH and
   the Proxmox web UI are unaffected). Verify the iGPU is now on vfio-pci:
   ```
   lspci -nnk -d 8086:5927        # "Kernel driver in use: vfio-pci"
   ```

6. **Start VM 101** (`qm start 101`).

## Part 2 — Apps VM: wire Jellyfin to the iGPU (software)

7. **Confirm the GPU reached the VM:**
   ```
   ls -l /dev/dri                 # expect card0 + renderD128
   lspci | grep -i vga            # the Intel Iris device
   ```

8. **Give the Jellyfin container the render node** via a host-specific
   `docker-compose.override.yml` at the repo root (gitignored — keeps the committed
   compose portable for forks/hosts without this GPU; auto-merged by docker compose).
   Read the GIDs first — they're the VM's, not the container's:
   ```bash
   getent group render | cut -d: -f3   # 993 here → group_add
   getent group video  | cut -d: -f3   # 44 here
   ```
   `~/coralstack-infra/docker-compose.override.yml`:
   ```yaml
   services:
     jellyfin:
       devices:
         - /dev/dri:/dev/dri
       group_add:
         - "993"   # render GID (this VM)
         - "44"    # video GID (this VM)
   ```
   Then `docker compose up -d jellyfin` and confirm `docker exec jellyfin ls /dev/dri`
   shows `renderD128`. (The Jellyfin image bundles its own ffmpeg + Intel drivers, so
   nothing extra is needed inside the guest.)

9. **Enable HW accel in Jellyfin:** Dashboard → Playback → Transcoding →
   - Hardware acceleration: **Intel QuickSync (QSV)** (VAAPI also works)
   - Device: `/dev/dri/renderD128`
   - Enable HW decoding for H264, HEVC, VP9; enable HW encoding.

   (This is stored in `encoding.xml`. Once validated, it's a candidate to template the
   same way `SSO-Auth.xml` is — see [ONBOARDING.md](ONBOARDING.md) — so it's reproducible.)

## Verify

- Play something that forces a transcode (lower the quality in the web player). The
  Jellyfin transcode log should now show `-hwaccel qsv`/`vaapi` instead of `libx264`.
- On the apps VM: `intel_gpu_top` (install `intel-gpu-tools`) shows the Video/Render
  engines busy during playback.

## Rollback

If passthrough misbehaves, revert from an SSH session on the host:
```
qm set 101 -delete hostpci0
rm /etc/modprobe.d/vfio.conf
update-initramfs -u -k all
reboot           # host reclaims the iGPU via i915
```

## Notes

- Capture the `hostpci0` line when the Proxmox VM config is moved to Terraform
  (`bpg/proxmox`) — see [PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) "VM definitions → Terraform".
- Only one VM can own the iGPU. If a second media VM ever needs HW transcode, that's the
  point to evaluate SR-IOV (not supported on this Kaby Lake part) or a newer host GPU.
