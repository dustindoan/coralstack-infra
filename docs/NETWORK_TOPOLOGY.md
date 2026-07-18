# Network topology — current state, target state, and the h3 decision

*Written 2026-07-17, after the Jellify/HTTP-3 investigation. Status: current
topology is Phase-1 transitional; the target ("product") topology is
documented here and deliberately deferred — it is a planned migration, not a
quick fix.*

## Current (Phase 1): double NAT

```
Internet ── Hitron FC777 (bridge) ── eero (public IP, NAT #1)
                                       │  192.168.4.0/24 (house LAN)
                                       ├─ family devices, Samsung TV, phones
                                       └─ Proxmox NUC (.10)
                                            └─ OPNsense VM (WAN .20, NAT #2)
                                                 └─ 10.0.0.0/24 (internal)
                                                      └─ Apps VM (.10) — Caddy + services
```

eero forwards TCP+UDP 443 → OPNsense WAN → Apps VM. LAN clients reach
services via public DNS → **eero hairpin NAT**.

### Known consequences of this topology (hard-won, do not re-learn)

1. **eero hairpin drops UDP/443** (2026-07-17, verified by isolation probes:
   h3 direct to OPNsense WAN = 82 ms; h3 via hairpin = blackhole). With Caddy
   advertising `alt-svc: h3` (30-day max-age), iOS clients cached the h3
   mapping per-app-container and hard-failed intermittently — root cause of
   the Jellify "one track then wedge" saga (see the Jellify memory). Web
   clients fall back gracefully; iOS does not. **Therefore h3 is disabled in
   the Caddyfile until the topology changes.**
2. **Source-based trust cannot cross the eero NAT** (SEC-1, 2026-07-16): the
   eero can launder internet traffic into the "trusted" 192.168.4.0/24 range,
   so an inner-firewall rule like "allow DNS from family LAN" is effectively
   "allow from internet" whenever a path exists. This is why split-horizon
   DNS served from OPNsense's WAN side is **permanently off the table** in
   this topology.

## Target ("product") topology: box as LAN peer

The topology CoralStack asks of member households — and therefore the one
this deployment should eventually dogfood. Three separated roles:

- **Routing** stays with the household router. Forever. CoralStack never
  demands the edge; edge-takeover (OPNsense on the bridged modem) remains an
  *enthusiast opt-in*, not a requirement.
- **Naming** is the one thing the box takes over: it serves household DNS
  (Pi-hole deployment model). Wildcard `*.{community}.coralstack.org` →
  box's LAN IP; everything else forwarded upstream. The only router ask in
  the entire design is "set custom DNS" (one field, universally supported,
  instantly revocable; public secondary resolver = graceful degradation).
  Same hostnames everywhere fall out of DNS geography: LAN clients resolve
  locally (direct path — TV, h3, no hairpin), remote clients resolve the
  public IP.
- **Reachability** for remote clients is one TCP+UDP 443 port-forward — the
  single most universally supported router feature. No edge VPS required.
  For households that structurally cannot forward (CGNAT, no router access):
  "edge" is a **role, not a rental** — another co-op site with a clean
  public path terminates their outbound tunnel and relays. A rented VPS is a
  scaling option, never architecture. (This preserves the earlier decision
  that architected the edge VPS out of the baseline; see the provisioning
  memory.)

In this topology h3 works by construction: LAN is direct (no NAT in path),
remote traverses one ordinary port-forward (no hairpin ever).

## Getting there from here: two Phase-2 forks

**A. Edge-takeover** — OPNsense onto the bridged Hitron, eero demoted to AP.
Max control and L2 isolation; the netadmin path. Diverges from what members
run.

**B. Flatten-to-product** — dissolve NAT #2; Apps VM joins the house LAN.
Dogfoods the member topology. Migration sketch (est. one afternoon, ~15–30
min downtime, clean rollback):

1. Apps VM NIC vmbr1 → vmbr0 (Proxmox, one setting) + netplan static IP on
   192.168.4.x + eero reservation.
2. eero 443 forward retargeted to the Apps VM.
3. DDNS re-homed from OPNsense to a `cloudflare-ddns` container (CF token
   already present for DNS-01).
4. Household DNS container on the Apps VM (wildcard override + upstream
   forward); eero custom DNS → Apps VM, secondary 1.1.1.1. SEC-1-safe here:
   resolver and clients share a segment, no NAT boundary, not
   internet-reachable.
5. Mac mini re-homed from OPT1 to the house LAN; update `OLLAMA_HOST`.
6. Bookkeeping: SSH config, RECOVERY/ADMIN_ACCESS/PROXMOX_MIGRATION docs.
   OPNsense VM parked powered-off (it is the fork-A option, not deleted).

Unaffected by design: certificates (DNS-01, no inbound dependency), USB
storage passthrough, GPU passthrough, all service data and compose configs.
Given up: the inner firewall between services and house LAN (acceptable —
every service already authenticates because it is internet-exposed; see
SECURITY_PASS auth map) and the OPNsense lab layer.

**Decision 2026-07-17: fork B is the intended direction but deferred** — it
is more impactful than a bugfix window. Until then h3 stays off.

## h3 re-enable bar

Re-enable (`caddy/Caddyfile`, remove the `servers { protocols h1 h2 }`
block) only when **all** of:

1. Topology no longer routes LAN clients through the eero hairpin (fork A or
   B complete, or split-horizon DNS safely deployed).
2. `curl --http3-only` succeeds against the service hostname from the LAN.
3. Same test passes from a WAN vantage (cellular hotspot) — verifies the
   router's UDP forward for remote clients.
4. A freshly-installed iOS client (delete app first — Alt-Svc cache lives in
   the app container for 30 days) survives multi-track playback.
