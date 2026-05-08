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
   │            ├─► family devices, WiFi
   │            │
   │            └─► port-forward 443 → 192.168.4.20 (OPNsense WAN)
   ▼
AirPort (bridge/switch mode — passes 802.1Q VLAN tags transparently)
   │                         │
   ▼                         ▼
NUC7i7BNH (single NIC)   Mac mini (admin/inference box)
   │                       untagged → 192.168.4.x (eero DHCP, not used by stack)
   [Proxmox VE]            VLAN 10  → 10.0.1.10 (OPNsense OPT1 DHCP reservation)
     │
     ├── vmbr0 (VLAN-aware bridge, physical NIC uplink)
     │     ├─ [untagged]  OPNsense vtnet0 (WAN @ 192.168.4.20)
     │     └─ [VLAN 10]   OPNsense vtnet2 (OPT1 @ 10.0.1.1/24 → Mac mini)
     │
     └── vmbr1 (internal-only, no physical NIC)
           ├─ OPNsense vtnet1 (LAN @ 10.0.0.1/24, runs DHCP for Apps VM)
           └─ Apps VM (10.0.0.10)
                Caddy + Ente + Jellyfin + Vaultwarden + Pocket ID + Open WebUI
                TerraMaster D4-320 via USB passthrough
                Open WebUI → Ollama on Mac mini (10.0.1.10:11434, via OPNsense routing)

     OPNsense port-forward: 443 → 10.0.0.10:443
     OPNsense firewall:     LAN (10.0.0.0/24) ↔ OPT1 (10.0.1.0/24) pass
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

8. **Configure network bridges.**

   Web UI → node → **Network** tab:
   - **Create → Linux Bridge** for `vmbr0`: address `192.168.4.10/24`, gateway `192.168.4.1`, bridge port `enp0s31f6`, check **VLAN aware**
   - **Create → Linux Bridge** for `vmbr1`: address `10.0.0.2/24`, no gateway, no bridge port (internal-only). The `10.0.0.2` is the Proxmox host's management presence on the OPNsense LAN — needed for SSH-tunnelling into the OPNsense web GUI from anywhere outside the DMZ. Without it, you have no path into OPNsense once VMs are running.
   - **Apply Configuration**

   If bridges already exist (e.g. created during install), click each one → **Edit** to set or verify the options, then **Apply Configuration**. The Edit button is only active when logged in as `root@pam` — if it's greyed out, log out and back in selecting PAM as the realm.

   If you prefer the CLI (equivalent to what the GUI writes), the relevant blocks should look like:
   ```
   auto vmbr0
   iface vmbr0 inet static
       address 192.168.4.10/24
       gateway 192.168.4.1
       bridge-ports enp0s31f6
       bridge-stp off
       bridge-fd 0
       bridge-vlan-aware yes
       bridge-vids 2-4094

   auto vmbr1
   iface vmbr1 inet static
       address 10.0.0.2/24
       bridge-ports none
       bridge-stp off
       bridge-fd 0
   ```
   Then `ifreload -a` to hot-apply without dropping the bridge.

   `vmbr0` must have **VLAN aware** set — without it the bridge strips 802.1Q tags and OPNsense's OPT1 interface (VLAN 10) never sees the Mac mini's traffic.

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
  - Device 1: Bridge `vmbr0`, Model `VirtIO`, **uncheck Firewall**, **write down the MAC address** — you need it for the eero reservation
  - Device 2: add after creation: Bridge `vmbr1`, Model `VirtIO`, **uncheck Firewall**
- Finish.

**Why Firewall: off on every VM NIC** — Proxmox's per-NIC firewall inserts an `fwbr/fwpr` veth chain between the VM tap and the host bridge. We don't use Proxmox's firewall (OPNsense itself is the firewall), and the chain creates a real fragility: any `ifreload -a` on the host bridges orphans the `fwpr` veths from the bridge, silently breaking VM connectivity until you `ip link set fwprNNNpX master vmbrY` manually. Disabling the per-NIC firewall removes the chain entirely — `tap` goes direct to `vmbr`, and `ifreload` becomes safe to run with VMs hot.

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
3. **Disable dnsmasq's DHCP first.** OPNsense 26.x ships with dnsmasq enabled by default; it grabs port 67 and Kea silently fails to bind with `DHCPSRV_OPEN_SOCKET_FAIL ... Address already in use`. Go to **Services → Dnsmasq DNS & DHCP → General**, uncheck **Enable**, Save → Apply. (Unbound is the default DNS resolver — disabling dnsmasq doesn't break DNS.) Verify nothing else is squatting on port 67: from the OPNsense shell, `sockstat -4 -l | grep :67` should return empty after this change.

4. **Services → Kea DHCPv4 → LAN:** OPNsense 26.x is on Kea (ISC is deprecated; the menu no longer shows ISC DHCPv4). Even if you enabled DHCP via the console Option 2, the Kea `Subnets` tab may be empty — the console config wrote to legacy ISC which the new UI doesn't surface. Reconfigure in Kea:
   - **General tab:** enable service, select LAN interface (the Interfaces field is multi-select — when you add OPT1 in Phase 3f, both LAN and OPT1 must be selected here, not just one)
   - **Subnets tab:** `+` add subnet `10.0.0.0/24`, pool `10.0.0.100-10.0.0.200` (plain ASCII hyphen, no spaces — Kea rejects en-dashes or spaces in the range). Leave "Auto collect option data" checked (pulls gateway/DNS from the LAN interface automatically — don't fill Router/DNS manually)
   - **Reservations tab:** add the Apps VM MAC → `10.0.0.10` mapping (defer until Apps VM is created in Phase 4 and its MAC is known)
   - Save → Apply
5. **Firewall → NAT → Destination NAT:** (renamed from "Port Forward" in OPNsense 26.x — same feature) add rule:
   - Interface: WAN
   - Protocol: TCP
   - Destination Address: WAN address
   - Destination Port: HTTPS
   - Redirect Target IP: **type `10.0.0.10` in the input field under the dropdown — easy to miss, leaving it empty silently drops traffic**
   - Redirect Target Port: **`443` (numeric, not the `HTTPS` alias)** — OPNsense 26.x rejects service aliases here because they can represent port ranges; redirect targets must be a single numeric port
   - Description: `Caddy HTTPS`
   - **Firewall rule: `Pass`** (OPNsense 26 renamed "Add associated filter rule (automatic)" to `Pass`. Don't leave as `Manual` — you'll get silent SYN drops because there's no matching pass rule on WAN.)
   - Save → Apply
6. **System → Settings → Administration:** optionally change root password, disable default password.
7. **Services → Dynamic DNS:** add Cloudflare DDNS for the home public IP. Use existing Cloudflare API token (scoped `Zone:DNS:Edit` on the coralstack zone).

**Naming pitfall:** OPNsense's "LAN" in this topology is your internal DMZ network (`10.0.0.0/24`). OPNsense's "WAN" is actually your home LAN (`192.168.4.0/24`). Default docs assume LAN=home; adjust mentally.

**Checkpoint:** OPNsense running, reachable on both interfaces, port-forward rule staged (target VM doesn't exist yet).

### 3f. Add OPT1 (VLAN 10) for Mac mini

This gives the Mac mini a stable IP managed entirely inside Proxmox/OPNsense, with no eero involvement. The AirPort in bridge/switch mode passes 802.1Q-tagged frames between the NUC and Mac mini transparently.

**Prerequisite:** `vmbr0` must have VLAN aware enabled (Phase 1 step 8). Verify in Proxmox web UI → node → Network → vmbr0 → Edit — the VLAN aware checkbox must be checked. If not, check it and Apply Configuration before proceeding.

**Add a third vNIC to the OPNsense VM (Proxmox web UI):**

OPNsense VM → Hardware → Add → Network Device:
- Bridge: `vmbr0`
- VLAN Tag: `10`
- Model: `VirtIO`
- **Uncheck Firewall** (same reasoning as Phase 3b — and especially important here: leaving Firewall on creates an auto-generated `vmbr0v10` sub-bridge that intercepts VLAN 10 traffic. If you ever toggle it off later, the sub-bridge is orphaned but `nic0.10` remains attached to it, silently swallowing traffic until you `ip link del nic0.10 && ip link del vmbr0v10`. Setting Firewall: off from the start avoids the trap entirely.)

This creates `vtnet2` inside OPNsense, carrying only VLAN-10 tagged frames from the physical AirPort segment.

**Configure OPT1 in OPNsense web GUI:**

1. **Interfaces → Assignments** → add `vtnet2` as `OPT1`. Save.
2. **Interfaces → OPT1:**
   - Enable: checked
   - IPv4 Configuration Type: Static
   - IPv4 Address: `10.0.1.1 / 24`
   - Save → Apply Changes
3. **Services → Kea DHCPv4:**
   - **General tab:** the Interfaces field must include **both LAN and OPT1** (multi-select). Adding OPT1 to the system as a new interface does NOT auto-include it here — you must re-edit and select it. If only LAN is selected, Kea won't listen on OPT1 even with a subnet defined; clients will get no replies and `DHCPSRV_NO_SOCKETS_OPEN` will appear in `/var/log/kea/`.
   - **OPT1 subnets tab:** `+` add `10.0.1.0/24`, pool `10.0.1.100-10.0.1.200` (plain hyphen, no spaces — Kea rejects en-dashes or spaces in the range)
   - Save → Apply
4. **Firewall → Rules → OPT1 → `+` add rule:**
   - Action: Pass, Protocol: Any
   - Source: OPT1 net, **Destination: `any`**
   - Description: `OPT1 → any (admin box: LAN, internet, firewall itself)`
   - Save

   Don't restrict the destination to `LAN net` — that prevents OPT1 clients from pinging OPNsense itself (`10.0.1.1`) for ARP/management. `any` is correct here; OPNsense's interface segregation is handled by which interface the rule lives on, not by destination.
5. **Firewall → Rules → LAN → `+` add rule:**
   - Action: Pass, Protocol: Any
   - Source: LAN net, Destination: OPT1 net
   - Description: `LAN → OPT1 (Apps VM to admin box / Ollama)`
   - Save → Apply Rules

**Add Mac mini DHCP reservation** (defer until Mac mini's VLAN interface MAC is known — complete in Phase 4c):

Services → Kea DHCPv4 → OPT1 → Reservations → `+`:
- MAC: `<mac-mini-vlan10-mac>` (shown in macOS System Settings → Network → VLAN interface → Details → Hardware)
- IP: `10.0.1.10`
- Save → Apply

## Phase 4 — Apps VM

### 4a. Create the VM

Web UI → Create VM:
- **General:** Name `apps`, VM ID 101, start at boot
- **OS:** ISO = Ubuntu Server 24.04 LTS
- **System:** default
- **Disks:** 100 GB on `local-lvm` (OS + Docker images; data lives on TerraMaster)
- **CPU:** 4 cores, type `host` (NUC7i7BNH is 2c/4t; 4 is the hard cap per VM. Over-commit with OPNsense's 2 is fine.)
- **Memory:** 16384 MB
- **Network:** Bridge `vmbr1`, Model `VirtIO`, **uncheck Firewall** (same reasoning as Phase 3b). **Write down the MAC.**
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
# from Proxmox host, apps VM is at 10.0.0.10 via OPNsense's DMZ.
# Proxmox already has 10.0.0.2/24 on vmbr1 (per Phase 1 step 8) so it can
# reach the Apps VM directly without any extra setup.
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

   **SSH key auth from your Mac, via Proxmox as a jump host.** You can't route into `10.0.0.10` directly (it's behind OPNsense's DMZ), but Proxmox can reach it via the `10.0.0.2/24` IP on `vmbr1` (configured in Phase 1 step 8). Use SSH ProxyJump:

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

   **Critical: fail-closed on unmount.** If the TerraMaster USB disappears (bus hiccup, enclosure power loss, unplug), the empty `/mnt/storage` directory reverts to being writable on the VM's root filesystem. Any service writing there (Ente's MinIO blobs, Jellyfin's library scans, etc.) will silently fill the 100GB OS disk in hours. Protect against this:
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

## Phase 4c — Mac mini (admin/inference box) network setup

The Mac mini gets two IP addresses: its existing untagged eero address (ignore it) and a new VLAN 10 address managed by OPNsense. The AirPort passes the tagged frames; nothing changes on eero.

**1. macOS VLAN interface (on the Mac mini):**

The Mac mini's GUI Network panel doesn't have a `+` for VLAN directly — it's tucked under the three-dots menu:

System Settings → Network → ⋯ menu → **Manage Virtual Interfaces** → `+` → New VLAN:
- Interface (parent): your **built-in Ethernet** — *not* a Thunderbolt Ethernet adapter. Some Thunderbolt adapters silently strip 802.1Q tags; the built-in NIC is reliable.
- VLAN ID: `10`
- VLAN Name: `CoralStack DMZ`
- Create

The BSD device name is typically `vlan0` (verify with `ifconfig | grep -A1 vlan`).

The new VLAN interface picks up a `10.0.1.x` address from OPNsense via DHCP. **Ignore the GUI's "Not Connected" status** — macOS shows that for VLAN interfaces even when they're working; trust `ifconfig`/`ping`, not the dot.

**2. Lock the IP via DHCP reservation:**

Find the VLAN interface MAC:
```bash
ifconfig vlan0 | grep ether
```

Enter that MAC in OPNsense → Services → Kea DHCPv4 → Reservations → `+` → IP `10.0.1.10` → Apply. Then renew the lease:
```bash
sudo ipconfig set vlan0 DHCP
ifconfig vlan0 | grep inet      # should show 10.0.1.10
```

**3. Verify connectivity:**
```bash
# from Mac mini
ping 10.0.1.1                   # OPT1 gateway
# from Apps VM (once Ollama is running)
curl http://10.0.1.10:11434/api/tags
```

The reverse direction (Mac mini → Apps VM at `10.0.0.10`) won't work without an OS-level route, but you don't need it for the Open WebUI use case. If you want it later, add it as a persistent route on macOS or push it via DHCP option 121 from Kea.

**4. Ollama (use the official Mac app, not Homebrew):**

Install from [ollama.com](https://ollama.com/download) — the Mac app has built-in auto-update and ships the `ollama` CLI. Homebrew's CLI-only formula doesn't auto-update without manual `brew upgrade`.

Bind it to all interfaces (defaults to localhost). The `launchctl setenv` approach is per-session and lost on reboot — make it permanent with a LaunchAgent at `~/Library/LaunchAgents/com.ollama.host.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>com.ollama.host</string>
    <key>ProgramArguments</key>
    <array><string>launchctl</string><string>setenv</string><string>OLLAMA_HOST</string><string>0.0.0.0</string></array>
    <key>RunAtLoad</key><true/>
  </dict>
</plist>
```
Load it:
```bash
launchctl load ~/Library/LaunchAgents/com.ollama.host.plist
```
Quit and relaunch the Ollama app. macOS Firewall will prompt to allow incoming connections — allow it.

**Optional: raise the GPU wired-memory cap.** Apple Silicon defaults to ~75% of unified RAM for GPU use. For 48GB Mac mini that's ~36GB, plenty for any Qwen 3.6 size. Only worth raising if you're running long-context (256K+) where KV cache grows large:
```bash
sudo sysctl iogpu.wired_limit_mb=45056
echo 'iogpu.wired_limit_mb=45056' | sudo tee -a /etc/sysctl.conf
```

**5. Headless setup** — so the Mac mini boots back online without a keyboard:

- **System Settings → General → Sharing → Remote Login: On** (note the SSH user shown)
- **System Settings → Users & Groups → Automatic login: \<your user\>** — required because the Ollama Mac app is a menu-bar GUI app and only starts when someone is logged in. Auto-login means power cycle = back online.
- Confirm the Ollama app's "Start Ollama on login" toggle is on (default).

**6. SSH access from your Mac** (via Apps VM as jump):
```
Host coralstack-mac-mini
    HostName 10.0.1.10
    User <mac-mini-user>
    ProxyJump coralstack-apps
```
Then push your key:
```bash
ssh-copy-id coralstack-mac-mini
```

After this you can unplug the monitor and keyboard — manage everything via SSH and Open WebUI.

**Checkpoint:** Mac mini reachable at `10.0.1.10` and via `ssh coralstack-mac-mini`, Ollama answering on `10.0.1.10:11434`, headless-ready (auto-login + Remote Login + persistent OLLAMA_HOST).

## Phase 5 — Cutover and validation

1. **Add eero port-forward.** Eero app → port-forward rule → external 443 → 192.168.4.20 (OPNsense WAN IP) → internal 443. Save.

2. **Update Cloudflare DNS records.** For each service subdomain (`photos.${BASE_DOMAIN}`, `media.${BASE_DOMAIN}`, etc.):
   - Change the A record from the old tailnet IP to your **current public IP** (what `curl ifconfig.me` returns from any device on your network, or `whatismyip.com`). OPNsense DDNS will keep this updated going forward.
   - Proxy status: DNS only (grey cloud). Never orange cloud per [infrastructure architecture memory](../../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_infrastructure_architecture.md) Layer 4.

3. **Test from outside.** From your phone on cellular (not home WiFi), hit each service URL. Caddy should serve TLS, services should respond.

4. **Test each service end-to-end:**
   - Pocket ID: login with existing passkey (or re-enroll if lost)
   - Vaultwarden: login, confirm vault decrypts
   - Ente Photos: web at `https://photos.${BASE_DOMAIN}`, log in with your
     Ente password (retrieve from Vaultwarden), confirm albums load.
     Mobile: configure server endpoint `https://photos-api.${BASE_DOMAIN}`,
     log in, trigger a backup.
   - Jellyfin: login, play a media file

**Checkpoint:** All services reachable publicly via TLS at expected URLs. Family can access without Tailscale.

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

**Storage + backup:**
- **Populate TerraMaster with 3 more 8TB drives + build mdadm RAID 6 + set up restic backups + offsite rotation.** See [backup strategy memory](../../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_backup_strategy.md). Trigger: when real data stops being expendable.
- **Export OPNsense `config.xml` to Tier 1 safe storage** (paper + USB in the physical safe). Diagnostics → Backup/Restore → Download configuration. Do this after any material firewall/NAT/DHCP change. Lets you rebuild OPNsense from scratch in minutes via Restore. Not IaC, but a valid backup posture until/unless we go full OPNsense-as-code.

**Infrastructure as code (not yet done — all documented in runbook as manual steps):**
- **Proxmox VM definitions → Terraform** (`bpg/proxmox` provider). Captures OPNsense + Apps VM hardware config, USB passthrough, start-at-boot order. Pays off when you rebuild either VM.
- **Cloudflare DNS → Terraform.** Cloudflare provider is mature. Single source of truth for subdomains. DDNS record is managed by OPNsense itself; Terraform owns the static wildcard.
- **OPNsense config → declarative** via either (a) `config.xml` import at first boot bundled with our installer ISO, or (b) ansible-role-style config push. (a) is simpler for homogeneous deployments, (b) scales better for per-member customization. Matches the "Phase 2 deliverable" in the [install simplicity target memory](../../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_install_simplicity_target.md).
- **Pocket ID config → API/SDK scripts.** OIDC client registrations, group definitions, group-to-client allowlist. Pocket ID has a REST API. A `pocket-id-bootstrap` script in the repo could replay the config against a fresh install. Would make member onboarding scripting trivial.
- **Jellyfin config → scripted bootstrap.** Local admin user, media library paths, SSO-Auth plugin provider configuration. Jellyfin has a REST API. Same pattern as Pocket ID — a bootstrap script that creates the admin, adds libraries, configures the plugin.
- **Vaultwarden config → bootstrap script.** Less critical since most state is user-created inside the vault, but the SSO config, admin token, and any org definitions could be scripted.

**Ente Photos (deferred enhancements, not trial-blocking):**
- **Pin Ente image versions.** `services/ente/.env` currently uses `ENTE_SERVER_VERSION=latest` and `ENTE_WEB_VERSION=latest`. Once the trial validates the deployment, switch to dated/digest-pinned tags so a `docker compose pull` doesn't surprise you. Track upstream at `ghcr.io/ente-io/server` and `ghcr.io/ente-io/web`.
- **Configure museum SMTP.** Currently OTT verification codes go to `docker compose logs ente-museum` because no SMTP block is set in `museum.yaml`. For a real production deploy, wire up an SMTP relay (Fastmail/Resend/SES) so members get verification + sharing emails directly. Schema is in `ente-io/ente:server/configurations/local.yaml` (`smtp:` block).
- **Add a working museum healthcheck.** Ente's upstream quickstart ships `curl --fail http://localhost:8080/ping`, but `ghcr.io/ente-io/server` doesn't include curl — the check always fails. Currently we omit the healthcheck entirely (better than a perpetual false negative). Replace with whatever's actually in the image (`wget`? Museum binary's own health subcommand if added?), or build a thin sidecar.
- **Remove the now-unused ente-socat sidecar.** Originally bridged museum's `localhost:3200` to ente-minio for the upstream-quickstart's S3 routing trick. Replaced 2026-04-24 by routing all S3 traffic through Caddy's `photos-storage.${BASE_DOMAIN}` route (museum's own S3 calls now go via Caddy too — same endpoint as clients see, signature consistency). Socat container is still defined and running but does nothing. Drop the service block when convenient.
- **Path A: museum OIDC-provisioning patch** ([spike chip queued separately](#known-followups)). Eliminates the OTT-from-logs ritual and the disable-registration toggle dance for new-member onboarding. Keeps SRP/E2EE crypto unchanged. Trigger: when onboarding household #2, or sooner if the toggle ritual gets annoying enough during the trial.
- **Watch upstream's MinIO migration.** Per [Ente strategy memory](../../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_ente_strategy.md), MinIO's GitHub repo was archived in early 2026; Ente will likely migrate the bundled object store (likely to Garage). When `ente-io/ente:server/quickstart.sh` shows a different stack, diff against our overlay and update.

**Network / hardware:**
- **Single-NIC VLAN segmentation is live** (Phase 3f + 4c above). The AirPort-as-dumb-switch + `bridge-vlan-aware yes` + OPNsense OPT1 approach gives the Mac mini a DMZ IP without touching eero and without a second physical NIC. The remaining limitation is no true L2 isolation between eero-LAN devices — all home devices share the untagged segment. That's acceptable for Phase 1 single-household.
- **Graduate past double-NAT.** Triggers: buying a firewall appliance (NanoPi R5S ~$100 / Protectli ~$250) with two physical NICs. Removes double-NAT, enables proper L2 isolation between WAN, home LAN, and DMZ without VLAN tricks.
- **Phase 2 edge services (Pangolin + Headscale)** — deferred until second community joins.

**Non-IaC-able (document, don't try to automate):**
- **eero config** (DHCP reservation, port-forward rule): consumer router with no stable API. Will always be a manual step documented for host-admins. If graduating past eero (see above), inherits Terraform-via-OPNsense or similar.

## Troubleshooting

- **Proxmox web UI unreachable after install:** verify NUC static IP config in `/etc/network/interfaces` survived reboot; check eero isn't reserving the same IP for another device.
- **OPNsense can't reach internet (WAN side):** confirm `192.168.4.20` is outside eero's DHCP pool, gateway is `192.168.4.1`, DNS servers reachable.
- **Apps VM can't reach internet (via OPNsense):** OPNsense → Firewall → Rules → LAN → ensure default "allow LAN to any" rule is present. Check NAT outbound mode is "automatic."
- **Port-forward not reaching Caddy:** verify chain: external curl → eero port-forward rule → OPNsense WAN firewall allowing 443 → OPNsense NAT rule → Apps VM listening on 443. Use `tcpdump` on OPNsense's WAN interface to see if packets arrive.
- **Caddy can't get certs:** same as QUICKSTART.md troubleshooting — verify `CF_API_TOKEN` scope, verify DNS propagated. All four Ente subdomains (`photos.`, `photos-api.`, `photos-accounts.`, `photos-albums.`) are single-level under `${BASE_DOMAIN}`, so the existing `*.${BASE_DOMAIN}` wildcard A record covers them all. Flat names were chosen specifically to avoid Cloudflare's wildcard limitation (a single `*.foo.example.com` record doesn't match `bar.foo.example.com`).
- **TerraMaster disappears from Apps VM after reboot:** USB passthrough by vendor/product ID is stable across reboots; if it's not, pin by USB bus/port path instead via `qm set 101 -usb0 host=<bus-port>`.
- **OPNsense DHCP reservation for Apps VM doesn't stick:** some VirtIO configs randomize MACs on VM recreation. Pin the MAC explicitly in the VM hardware config.
- **Family WiFi / eero behaving differently:** this migration doesn't touch eero DHCP/DNS/firewall for existing devices — only adds one new port-forward rule and one reservation. If anything changed family-side, it's unrelated.
- **OPNsense GUI unreachable from outside the DMZ:** SSH-tunnel through Proxmox: `ssh -L 8443:10.0.0.1:443 coralstack-nuc`, then browse `https://localhost:8443`. Same pattern works for Proxmox itself: `ssh -L 8006:192.168.4.10:8006 coralstack-nuc` → `https://localhost:8006`.
- **Proxmox GUI Edit button greyed out:** node-level Network edits require `root@pam` realm specifically, not Linux PAM users in the `pve` realm. Log out, log back in selecting **PAM** explicitly.
- **OPNsense LAN interface lost its `10.0.0.1` IP and is DHCPing from itself:** symptom — `ifconfig vtnet1` shows `10.0.0.100` (or another DHCP-pool address) instead of `10.0.0.1`. Recovery: from OPNsense console option **2) Set interface IP address** → choose LAN → "Configure IPv4 via DHCP?" `N` → IPv4 `10.0.0.1`/`24` → no upstream gateway → "Enable DHCP server" `N` (Kea handles it now) → "Restore web GUI defaults" `N`. Cause is unclear — appears related to interface re-assignments triggering a DHCP fallback in OPNsense's startup config.
- **`fwpr*` veth orphaned from `vmbr*` after `ifreload -a`:** symptom — VM connectivity lost, `bridge link show` shows `tap*` on `fwbr*` but the corresponding `fwpr*` has no master. Quick fix: `ip link set fwprNNNpX master vmbrY`. Permanent fix: disable Proxmox per-NIC firewall on the affected NIC (Hardware → netN → Edit → uncheck Firewall). With firewall off there's no `fwbr/fwpr` chain to orphan — `tap` goes direct to bridge.
- **OPT1 traffic vanishes after disabling Proxmox firewall on a VLAN-tagged NIC:** Proxmox auto-creates a `vmbr0v<vlan>` sub-bridge when firewall is enabled on a tagged NIC. Toggling firewall off later orphans the sub-bridge but leaves `nic0.<vlan>@nic0` attached to it, intercepting all VLAN traffic. Fix: `ip link del nic0.<vlan> && ip link del vmbr0v<vlan>`. Avoid by setting Firewall: off on tagged NICs from the start (Phase 3f covers this).
- **dnsmasq squats port 67, Kea fails to bind silently:** symptom — Kea logs `DHCPSRV_OPEN_SOCKET_FAIL ... Address already in use` for vtnet1/vtnet2; `sockstat -4 -l | grep :67` shows dnsmasq. Disable Services → Dnsmasq DNS & DHCP → uncheck Enable. Unbound is the default DNS resolver and unaffected.
- **Kea Subnets save error "Entry X is not a valid range or subnet":** copy-pasted en-dash (`–`) or whitespace-padded hyphen in the pool. Use a plain ASCII hyphen with no surrounding spaces: `10.0.1.100-10.0.1.200`.
- **OPT1 firewall rule with `Destination: LAN net` blocks ICMP to OPNsense itself:** symptom — Mac mini can ping nothing on OPT1 (`10.0.1.1` fails) even though DHCP works. The rule needs `Destination: any`, not `LAN net`. Pinging the firewall's own OPT1 address is to "this firewall," not "LAN net."
