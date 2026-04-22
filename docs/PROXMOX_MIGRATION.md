# Proxmox migration runbook

Phase 1 migration from bare-metal Ubuntu Server + Docker on NUC to Proxmox hypervisor
+ OPNsense VM + Apps VM. One-weekend work budget for a clean migration.

Preserves existing coralstack-infra stack, shifts from tailnet-only access to
direct public exposure via OPNsense + eero port-forward, prepares the
apps-VM slot where the Ente trial will be added.

## Architecture overview

```
Internet
   │
   ▼
ISP modem (Hitron FC777, bridge mode, single public IP)
   │
   ▼
eero (NAT, DHCP, primary home router, 192.168.4.0/24)
   │            │
   │            ├─► family devices, WiFi, AirPort
   │            │
   │            └─► port-forward 443 → 192.168.4.20 (OPNsense WAN)
   ▼
NUC7i7BNH (single NIC, 32GB RAM)
   │
   [Proxmox VE bare-metal]
     │
     ├── vmbr0 (bridged to physical NIC, home LAN side)
     └── vmbr1 (internal-only, no physical NIC, DMZ side)
         │
         ┌──────────────────┼──────────────────┐
         │                                     │
     OPNsense VM                           Apps VM
     WAN: vmbr0 (192.168.4.20 static,      (10.0.0.10, reserved by OPNsense)
          pinned via eero DHCP reservation) Caddy + Immich + Jellyfin +
     LAN: vmbr1 (10.0.0.1/24, runs         Vaultwarden + Pocket ID
          DHCP for Apps VM)                TerraMaster D4-320 via USB passthrough
     Port-forward 443 → 10.0.0.10:443
```

See [Phase 1 trial-phase accepted compromises](../../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_infrastructure_architecture.md) for the honest framing of what this buys vs. deferred improvements.

## Prerequisites and prep

- USB drive (8GB+) for Proxmox installer
- USB drive (8GB+) for OPNsense installer
- Keyboard + monitor for initial NUC install (or use Proxmox's remote install via IPMI-alike; NUCs don't have IPMI)
- A second machine (laptop) with SSH client for post-install admin
- Proxmox web UI will be reachable at `https://<nuc-lan-ip>:8006` once installed

### Images to download ahead of time

| What | Where | Notes |
| ---- | ----- | ----- |
| Proxmox VE ISO | [proxmox.com/en/downloads](https://www.proxmox.com/en/downloads) | Latest stable (9.x) |
| OPNsense ISO | [opnsense.org/download/](https://opnsense.org/download/) | `dvd` image, `amd64`, nearest mirror |
| Ubuntu Server 24.04 LTS ISO | [ubuntu.com/download/server](https://ubuntu.com/download/server) | for Apps VM; `live-server` amd64 |

Flash Proxmox ISO to its USB with `dd` or Balena Etcher. The others get uploaded to Proxmox later.

## Phase 0 — Backups and pre-flight

Scope is "fine to lose most work," but preserve the handful of things that are
expensive to recreate. Everything else gets wiped when Proxmox installs.

1. **Vaultwarden encrypted export**
   ```bash
   # from the current NUC, before migration
   docker compose exec vaultwarden /vaultwarden backup dump > ~/vw-backup.tar.gz
   ```
   Copy `~/vw-backup.tar.gz` to a USB drive. It's E2E-encrypted; safe to hold offline.

2. **Save current secrets**
   ```bash
   cd /path/to/coralstack-infra
   cp .env ~/coralstack-env.backup
   for svc in services/*/; do
     [ -f "$svc/.env" ] && cp "$svc/.env" ~/coralstack-$(basename $svc)-env.backup
   done
   ```
   Secrets aren't in git — if lost, each service regenerates theirs, but breaks any existing sessions/keys.

3. **Inventory what's on the TerraMaster.** It's external USB, survives the NUC wipe.
   ```bash
   df -h /path/to/terramaster/mount
   ls /path/to/terramaster/mount
   ```
   Confirm photo libraries, media files, etc. are where you expect.

4. **Note the current setup**
   - Current NUC LAN IP (may want to reuse): `ip addr show`
   - Services currently running publicly reachable: `docker compose ps`
   - Cloudflare DNS records pointing at current setup: if they point at tailnet IPs, you'll update them to point at the public IP after migration

5. **NUC BIOS check**
   - Reboot NUC, press F2 at boot for BIOS
   - **Enable Intel VT-x** (virtualization) — Advanced → Processor
   - **Enable Intel VT-d** (IOMMU) — Advanced → Processor
   - Save, reboot

6. **Power off NUC** once backups are verified on the USB drive.

## Phase 1 — Proxmox install

1. **Boot from Proxmox installer USB.** Select "Install Proxmox VE (Graphical)".

2. **Target disk:** the NUC's M.2 SSD. **This wipes everything.** Confirmed acceptable per scope.

3. **Filesystem:** ext4 (avoid ZFS on single-disk without UPS).

4. **Network config during install:**
   - Management interface: the built-in NIC (`enp0s31f6` typical on NUC7)
   - **Static IP on home LAN:** `192.168.4.10/24` (or whatever is outside your eero DHCP range)
   - Gateway: `192.168.4.1` (eero)
   - DNS: `192.168.4.1` or `1.1.1.1`
   - Hostname: `coralstack-nuc` or similar

5. **Finish install, reboot, remove USB.**

6. **First login via SSH**
   ```bash
   ssh root@192.168.4.10
   ```
   **Quality-of-life:** push your Mac's SSH key and add a host alias so you're not typing the diceware every time:
   ```bash
   ssh-copy-id root@192.168.4.10   # one-time, requires the Proxmox diceware once
   ```
   Then add to `~/.ssh/config`:
   ```
   Host coralstack-nuc
       HostName 192.168.4.10
       User root
   ```
   After this, `ssh coralstack-nuc` works without a password. The Apps VM jump config gets added in Phase 4.

7. **Disable enterprise repo, enable no-subscription**
   ```bash
   # PVE 9 uses deb822-style sources (*.sources files); PVE 8 used *.list.
   # Pick the one that matches what's actually on disk.
   ls /etc/apt/sources.list.d/
   # If you see pve-enterprise.sources (PVE 9):
   sed -i 's/^Enabled: true/Enabled: false/' /etc/apt/sources.list.d/pve-enterprise.sources 2>/dev/null || true
   sed -i 's/^Enabled: true/Enabled: false/' /etc/apt/sources.list.d/ceph.sources 2>/dev/null || true
   cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
   # If you see pve-enterprise.list (PVE 8), fall back to the old format:
   # sed -i 's/^deb/# deb/' /etc/apt/sources.list.d/pve-enterprise.list
   # echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
   apt update && apt full-upgrade -y
   reboot
   ```

8. **Configure network bridges.** Edit `/etc/network/interfaces`:
   ```
   auto vmbr0
   iface vmbr0 inet static
       address 192.168.4.10/24
       gateway 192.168.4.1
       bridge-ports enp0s31f6
       bridge-stp off
       bridge-fd 0
       # existing bridge, carries home LAN traffic

   auto vmbr1
   iface vmbr1 inet manual
       bridge-ports none
       bridge-stp off
       bridge-fd 0
       # internal-only bridge for Apps VM <-> OPNsense DMZ
   ```
   ```bash
   systemctl restart networking
   # verify both bridges appear
   ip link show
   ```

9. **Verify via web UI.** Open `https://192.168.4.10:8006` from your laptop. Log in as `root`. Dismiss the no-subscription notice.

**Checkpoint:** Proxmox is up, reachable via SSH and web UI, two bridges configured, system updated.

## Phase 2 — eero prep

1. **Add DHCP reservation for OPNsense's WAN interface.**
   Eero app → Home → Network Settings → Reservations & Port Forwards
   - Device: will be the OPNsense VM's vNIC — you'll register the MAC after creating the VM in Phase 3. Skip this substep for now; come back to it.

2. **Port-forward rule:** defer until OPNsense is up and has its IP.

## Phase 3 — OPNsense VM

### 3a. Upload OPNsense ISO to Proxmox

Web UI → `local` storage → ISO Images → Upload → OPNsense ISO.

### 3b. Create the VM

Web UI → Create VM:
- **General:** Name `opnsense`, VM ID 100, start at boot
- **OS:** ISO = OPNsense, Type Linux (closest match — FreeBSD isn't a dropdown option)
- **System:** default
- **Disks:** 20 GB on `local-lvm`, **Bus: SATA** (FreeBSD + VirtIO SCSI single is flaky — SATA is rock-solid for the OPNsense installer)
- **CPU:** 2 cores, type `host`
- **Memory:** 4096 MB (OPNsense 25.x UFS installer warns below ~3GB)
- **Network:**
  - Device 1: Bridge `vmbr0`, Model `VirtIO`, **write down the MAC address** — you need it for the eero reservation
  - Device 2: add after creation: Bridge `vmbr1`, Model `VirtIO`
- Finish.

### 3c. Add OPNsense's WAN MAC to eero reservation

Back in the eero app, add the DHCP reservation pinning that MAC to `192.168.4.20` (or any IP outside eero's DHCP pool).

### 3d. Install and console-configure OPNsense

1. Start the VM, open the web console in Proxmox
2. Login as `installer` / `opnsense` (factory default — kicks off guided installer; logging in as `root` drops to shell)
3. **Install mode: `Install (ZFS)`**, Pool Type `stripe - No Redundancy`, select `ada0`, confirm `YES` on Last Chance prompt.
   - UFS install fails on OPNsense 25.x fresh VM disks (`Partition destroy failed` on empty-schemed disk). Don't waste time on it.
4. Set a fresh diceware root password (not reused from Proxmox or vault — secret tiering)
5. Before the reboot after install, detach the ISO: Proxmox VM → Hardware → CD/DVD → "Do not use any media"
6. Reboot, login as `root` / `<your diceware>` at the console
5. Console option 1 — **Assign interfaces:**
   - WAN = `vtnet0` (the vmbr0 vNIC)
   - LAN = `vtnet1` (the vmbr1 vNIC)
   - No VLAN
6. Console option 2 — **Set IP addresses:**
   - LAN: static IPv4 = `10.0.0.1`, subnet `24`, DHCP server `yes`, DHCP range `10.0.0.100`–`10.0.0.200`, HTTPS web GUI `yes`

### 3e. Initial web config

From a laptop on the home LAN, browse `https://192.168.4.20` (the WAN IP). If the WAN firewall is blocking web-GUI, temporarily allow it:
- Console option 11 — Reload all services, *OR*
- Temporarily run the console shell and `pfctl -d` to disable firewall

OR (cleaner): plug a laptop into a Proxmox host port and bridge it onto vmbr1 to access OPNsense via the LAN IP `10.0.0.1`. For this, use Proxmox's built-in console or spin up a temporary Ubuntu VM on vmbr1 for browser access.

Once in the web GUI:

1. **Interfaces → WAN:** set static IPv4 `192.168.4.20/24`, gateway `192.168.4.1` (eero). Uncheck "Block private networks" and "Block bogon networks" (WAN is on a private network).
2. **Interfaces → LAN:** confirm `10.0.0.1/24`.
3. **Services → Kea DHCPv4 → LAN:** OPNsense 26.x is on Kea (ISC is deprecated; the menu no longer shows ISC DHCPv4). Even if you enabled DHCP via the console Option 2, the Kea `Subnets` tab may be empty — the console config wrote to legacy ISC which the new UI doesn't surface. Reconfigure in Kea:
   - **General tab:** enable service, select LAN interface
   - **Subnets tab:** `+` add subnet `10.0.0.0/24`, pool `10.0.0.100-10.0.0.200`. Leave "Auto collect option data" checked (pulls gateway/DNS from the LAN interface automatically — don't fill Router/DNS manually)
   - **Reservations tab:** add the Apps VM MAC → `10.0.0.10` mapping (defer until Apps VM is created in Phase 4 and its MAC is known)
   - Save → Apply
4. **Firewall → NAT → Destination NAT:** (renamed from "Port Forward" in OPNsense 26.x — same feature) add rule:
   - Interface: WAN
   - Protocol: TCP
   - Destination Address: WAN address
   - Destination Port: HTTPS
   - Redirect Target IP: **type `10.0.0.10` in the input field under the dropdown — easy to miss, leaving it empty silently drops traffic**
   - Redirect Target Port: **`443` (numeric, not the `HTTPS` alias)** — OPNsense 26.x rejects service aliases here because they can represent port ranges; redirect targets must be a single numeric port
   - Description: `Caddy HTTPS`
   - **Firewall rule: `Pass`** (OPNsense 26 renamed "Add associated filter rule (automatic)" to `Pass`. Don't leave as `Manual` — you'll get silent SYN drops because there's no matching pass rule on WAN.)
   - Save → Apply
5. **System → Settings → Administration:** optionally change root password, disable default password.
6. **Services → Dynamic DNS:** add Cloudflare DDNS for the home public IP. Use existing Cloudflare API token (scoped `Zone:DNS:Edit` on the coralstack zone).

**Naming pitfall:** OPNsense's "LAN" in this topology is your internal DMZ network (`10.0.0.0/24`). OPNsense's "WAN" is actually your home LAN (`192.168.4.0/24`). Default docs assume LAN=home; adjust mentally.

**Checkpoint:** OPNsense running, reachable on both interfaces, port-forward rule staged (target VM doesn't exist yet).

## Phase 4 — Apps VM

### 4a. Create the VM

Web UI → Create VM:
- **General:** Name `apps`, VM ID 101, start at boot
- **OS:** ISO = Ubuntu Server 24.04 LTS
- **System:** default
- **Disks:** 100 GB on `local-lvm` (OS + Docker images; data lives on TerraMaster)
- **CPU:** 4 cores, type `host` (NUC7i7BNH is 2c/4t; 4 is the hard cap per VM. Over-commit with OPNsense's 2 is fine.)
- **Memory:** 16384 MB
- **Network:** Bridge `vmbr1`, Model `VirtIO`. **Write down the MAC.**
- Finish, but don't start yet.

### 4b. Add the TerraMaster USB passthrough

Connect the TerraMaster D4-320 to the NUC via USB-C. Power it on.

On the Proxmox host:
```bash
lsusb
# identify the TerraMaster — vendor/product ID will look something like Bus 002 Device 003: ID 152d:0578
```

Add USB passthrough to the VM:
Web UI → apps VM → Hardware → Add → USB Device → Use USB Vendor/Device ID → select the TerraMaster. Check "Use USB3."

(Alternative: `qm set 101 -usb0 host=152d:0578,usb3=1` via CLI.)

### 4c. Add MAC to OPNsense DHCP reservation

OPNsense web GUI → Services → DHCPv4 → LAN → Static Mappings → add MAC → `10.0.0.10`.

### 4d. Install Ubuntu Server

Start the VM, install Ubuntu Server 24.04 LTS via console (Subiquity installer):
- Language / keyboard: defaults
- Network: DHCP on the single NIC (OPNsense will hand out `10.0.0.10` once you map the MAC in 4c)
- Proxy / mirror: defaults
- Storage: "Use an entire disk"
  - **⚠️ Installer defaults to largest disk — that's the TerraMaster, NOT what you want.** Explicitly select the 100GB `sda` (QEMU HARDDISK) as the target. If the TerraMaster is accepted, you wipe the 8TB drive and leave the VM disk unused.
  - **Uncheck "Set up this disk as an LVM group"** — default is on; for a single-disk VM, LVM adds a layer with no benefit. Resize via Proxmox + `growpart`/`resize2fs` is simpler than LVM ops.
- Profile: hostname `apps`, your admin user, strong password
- SSH: **enable OpenSSH server**, import keys from GitHub/Launchpad if you want (optional)
- Snaps: skip all featured snaps
- Let it install, reboot, remove ISO.

### 4e. Post-install config

SSH from the Proxmox host (handy because management is there):
```bash
# from Proxmox host, apps VM is at 10.0.0.10 via OPNsense's network — need a route
# easiest: SSH into OPNsense first via console, or install a tunneling SSH config
# simplest for this step: temporarily add a LAN-side IP on Proxmox for vmbr1

# On Proxmox host:
ip addr add 10.0.0.2/24 dev vmbr1
ssh admin@10.0.0.10
```

On the Apps VM:

0. **Admin ergonomics** (quality-of-life; do this first to save typing the install-time diceware every sudo).

   **Passwordless sudo for your admin user** — acceptable on a dedicated single-admin homelab box because real access control is SSH key auth, not the sudo password:
   ```bash
   echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/99-$USER
   sudo chmod 0440 /etc/sudoers.d/99-$USER
   # verify
   sudo whoami   # should print "root" with no prompt
   ```

   Alternative if you prefer to keep sudo prompting: extend the cache to 60 minutes:
   ```bash
   echo "Defaults timestamp_timeout=60" | sudo tee /etc/sudoers.d/99-timeout
   sudo chmod 0440 /etc/sudoers.d/99-timeout
   ```

   **SSH key auth from your Mac, via Proxmox as a jump host.** You can't route into `10.0.0.10` directly (it's behind OPNsense's DMZ), but Proxmox can reach it via the `10.0.0.2/24` IP we added to `vmbr1`. Use SSH ProxyJump:

   ```bash
   # from your Mac, one-time: push your key to the Apps VM via the jump
   ssh-copy-id -o ProxyJump=root@192.168.4.10 <your-user>@10.0.0.10
   ```

   Then add to `~/.ssh/config` on your Mac for convenience:
   ```
   Host coralstack-nuc
       HostName 192.168.4.10
       User root

   Host coralstack-apps
       HostName 10.0.0.10
       User <your-user>
       ProxyJump root@192.168.4.10
   ```

   After this, `ssh coralstack-apps` gets you into the VM shell with full Mac clipboard support. **Much better than fighting noVNC** — Proxmox 9's noVNC dropped the clipboard icon, so pasting is near-impossible from the browser terminal. Use SSH for anything beyond a handful of keystrokes.

1. **Mount the TerraMaster disk(s)** — they appear as `/dev/sdb`, `/dev/sdc`, etc.
   ```bash
   sudo mkfs.ext4 -L coralstack /dev/sdb   # ONLY if it's a fresh drive — if existing data, skip!
   sudo mkdir -p /mnt/storage
   sudo mount /dev/sdb /mnt/storage
   echo 'LABEL=coralstack /mnt/storage ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
   ```
   **If the drive has existing data from the old setup, just mount it — don't mkfs.** Using `LABEL=` in fstab means the mount survives USB enumeration reshuffles.

   **Critical: fail-closed on unmount.** If the TerraMaster USB disappears (bus hiccup, enclosure power loss, unplug), the empty `/mnt/storage` directory reverts to being writable on the VM's root filesystem. Any service writing there (Immich, Jellyfin, etc.) will silently fill the 100GB OS disk in hours. Protect against this:
   ```bash
   sudo umount /mnt/storage
   sudo chmod 000 /mnt/storage   # lock down the bare directory
   sudo mount /mnt/storage        # re-mount from fstab
   sudo systemctl daemon-reload   # silences the fstab/systemd drift hint
   ```
   When mounted, the filesystem's permissions apply (normal). When *not* mounted, the bare directory has `000` — services fail with EACCES instead of silently corrupting root.

   **Verify it actually works** — this is cheap and proves the protection is real:
   ```bash
   sudo umount /mnt/storage
   ls -ld /mnt/storage              # expect: d--------- (no permissions)
   touch /mnt/storage/test 2>&1     # expect: "Permission denied"
   sudo mount /mnt/storage          # re-mount
   ls -ld /mnt/storage              # expect: drwxr-xr-x (FS perms show through)
   ```
   If the first `ls -ld` shows anything other than `d---------`, the chmod 000 didn't stick — re-run it.

2. **Install Docker**
   ```bash
   curl -fsSL https://get.docker.com | sudo sh
   sudo usermod -aG docker $USER
   # log out and back in for the group to take effect
   ```

3. **Clone coralstack-infra**
   ```bash
   git clone <your-repo-url> ~/coralstack-infra
   cd ~/coralstack-infra
   ```

4. **Restore .env files**
   Copy the backups from Phase 0 back into place:
   ```bash
   cp ~/coralstack-env.backup .env
   for svc_env in ~/coralstack-*-env.backup; do
     svc=$(echo "$svc_env" | sed 's/.*coralstack-\(.*\)-env\.backup/\1/')
     cp "$svc_env" "services/$svc/.env"
   done
   ```
   Update `STORAGE_PATH=/mnt/storage` if the mount point differs from before.

5. **Run setup.sh**
   ```bash
   ./setup.sh
   ```
   Bring up services. Verify each one starts cleanly.

6. **Restore Vaultwarden data** (if the `/data/vaultwarden` directory from the old setup was on the TerraMaster, it's already there; otherwise import the encrypted export via the Vaultwarden web UI once containers are up).

**Checkpoint:** Apps VM running, services up on internal `https://<service>.${BASE_DOMAIN}` reachable via OPNsense LAN.

## Phase 5 — Cutover and validation

1. **Add eero port-forward.** Eero app → port-forward rule → external 443 → 192.168.4.20 (OPNsense WAN IP) → internal 443. Save.

2. **Update Cloudflare DNS records.** For each service subdomain (`photos.${BASE_DOMAIN}`, `media.${BASE_DOMAIN}`, etc.):
   - Change the A record from the old tailnet IP to your **current public IP** (what `curl ifconfig.me` returns from any device on your network, or `whatismyip.com`). OPNsense DDNS will keep this updated going forward.
   - Proxy status: DNS only (grey cloud). Never orange cloud per [infrastructure architecture memory](../../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_infrastructure_architecture.md) Layer 4.

3. **Test from outside.** From your phone on cellular (not home WiFi), hit each service URL. Caddy should serve TLS, services should respond.

4. **Test each service end-to-end:**
   - Pocket ID: login with existing passkey (or re-enroll if lost)
   - Vaultwarden: login, confirm vault decrypts
   - Immich: login, browse library, trigger a mobile upload
   - Jellyfin: login, play a media file

5. **Clean up temporary Proxmox bridge IP:**
   ```bash
   # on Proxmox host
   ip addr del 10.0.0.2/24 dev vmbr1
   ```

**Checkpoint:** All services reachable publicly via TLS at expected URLs. Family can access without Tailscale.

## Phase 6 — Add Ente (after baseline is stable)

**Don't do this on migration weekend.** Let the baseline bake for at least a few days with your real usage before adding the Ente trial.

When ready:

1. **Create `services/ente/docker-compose.yml`** using upstream include pattern (matches Immich precedent from commit 6a1a9d5):
   ```yaml
   include:
     - path: https://raw.githubusercontent.com/ente-io/ente/<PIN_TAG>/server/compose.yaml
   services:
     # overrides only: network attachment to coralstack, env pins, etc.
   ```
   Pin `<PIN_TAG>` to a specific Ente release tag (check Ente's releases page).

2. **Add to root `docker-compose.yml`** `include:` list, analogous to Immich's entry.

3. **Add Ente's `.env`** — Ente's docs (ente.com/help/self-hosting/installation/compose) lay out the required vars. Store S3 bucket endpoint pointing at whatever S3 layer Ente's upstream compose ships (currently MinIO; likely to change post-archival). Check [Ente strategy memory](../../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_ente_strategy.md) for context.

4. **Add Caddy routes** for `photos-ente.${BASE_DOMAIN}` (or similar) pointing at the museum container.

5. **Add Cloudflare DNS record** for the new subdomain.

6. **Bring up.** Test mobile upload. Run the ~1 month trial per memory's success criteria.

## Rollback plan

If Proxmox migration has a catastrophic failure partway through and you need to get back to a working state fast:

1. **Don't panic.** The Proxmox install is on the NUC's M.2 SSD. The TerraMaster is untouched.
2. **Reinstall bare-metal Ubuntu Server** onto the NUC from a fresh installer USB.
3. **Restore `.env` files** from Phase 0 backups.
4. **Mount TerraMaster** as before, keep data in place.
5. **Bring up the old compose** the same way it was running before migration.
6. **Revert Cloudflare DNS** to tailnet IPs.

Total rollback time: ~2-3 hours if backups are organized.

## Known followups (not trial-blocking)

Track these so they don't fall off the radar:

- **Populate TerraMaster with 3 more 8TB drives + build mdadm RAID 6 + set up restic backups + offsite rotation.** See [backup strategy memory](../../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_backup_strategy.md). Trigger: when real data stops being expendable.
- **Convert VM creation to Terraform** (`bpg/proxmox` provider). Captures the OPNsense + Apps VM definitions as code. Pays off when you rebuild either VM.
- **Move Cloudflare DNS records to Terraform.** Cloudflare provider is mature. Single source of truth for subdomains.
- **Graduate past single-NIC bridge-mode.** Triggers: buying a firewall appliance (NanoPi R5S ~$100 / Protectli ~$250) OR adding a managed switch for router-on-a-stick. Removes double-NAT, enables physical L2 isolation.
- **Phase 2 edge services (Pangolin + Headscale)** — deferred until second community joins.

## Troubleshooting

- **Proxmox web UI unreachable after install:** verify NUC static IP config in `/etc/network/interfaces` survived reboot; check eero isn't reserving the same IP for another device.
- **OPNsense can't reach internet (WAN side):** confirm `192.168.4.20` is outside eero's DHCP pool, gateway is `192.168.4.1`, DNS servers reachable.
- **Apps VM can't reach internet (via OPNsense):** OPNsense → Firewall → Rules → LAN → ensure default "allow LAN to any" rule is present. Check NAT outbound mode is "automatic."
- **Port-forward not reaching Caddy:** verify chain: external curl → eero port-forward rule → OPNsense WAN firewall allowing 443 → OPNsense NAT rule → Apps VM listening on 443. Use `tcpdump` on OPNsense's WAN interface to see if packets arrive.
- **Caddy can't get certs:** same as QUICKSTART.md troubleshooting — verify `CF_API_TOKEN` scope, verify DNS propagated.
- **TerraMaster disappears from Apps VM after reboot:** USB passthrough by vendor/product ID is stable across reboots; if it's not, pin by USB bus/port path instead via `qm set 101 -usb0 host=<bus-port>`.
- **OPNsense DHCP reservation for Apps VM doesn't stick:** some VirtIO configs randomize MACs on VM recreation. Pin the MAC explicitly in the VM hardware config.
- **Family WiFi / eero behaving differently:** this migration doesn't touch eero DHCP/DNS/firewall for existing devices — only adds one new port-forward rule and one reservation. If anything changed family-side, it's unrelated.
