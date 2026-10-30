# Network topology — current state, target state, and the h3 decision

*Written 2026-07-17, after the Jellify/HTTP-3 investigation. Status: current
topology is Phase-1 transitional; the target ("product") topology is
documented here and deliberately deferred — it is a planned migration, not a
quick fix. Updated 2026-10-26: other boxes sharing this household's 443;
reframed 2026-10-29 as Atoll, the household's platform (below).*

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

**`http://` does not redirect to `https://`, and that is deliberate.** Typing a
literal `http://id.<BASE_DOMAIN>` gets a connection failure, not a redirect.
Caddy is not misconfigured — its own config validation reports *"enabling
automatic HTTP->HTTPS redirects"* and it listens on 80 inside the container.
The port is simply never reachable: the root `docker-compose.yml` publishes only
`443:443` and `443:443/udp`, and only 443 is forwarded at the eero. That follows
from the box-as-LAN-peer decision below — **one** 443 forward, not two.

It costs nothing on certificates, because DNS-01 via Cloudflare is used rather
than HTTP-01. HTTP-01 would have *required* :80 reachable from the internet,
which is one of the reasons DNS-01 was chosen.

Practical impact is narrow: current browsers try HTTPS first for a bare hostname
typed in the address bar, and anyone who has visited once is covered by HSTS,
which Caddy sets by default. Only an explicit `http://` fails.

Wanting redirects means publishing `80:80` **and** adding a second forward at
the eero — trading the one-port property for a convenience and putting another
listener on the internet. Measured 2026-10-15; recorded because the symptom
looks like a Caddy bug and is not one.


1. **RETRACTED, then corrected (2026-07-17, same day):** an isolation probe
   appeared to show the eero hairpin dropping UDP/443 (h3 direct to OPNsense
   WAN = 82 ms; h3 "via hairpin" = blackhole), and h3 was disabled on that
   basis. The probe was later discovered to have run while the admin's Mac
   was on a VPN — the "hairpin" leg actually went VPN→WAN, so the result
   says nothing about the hairpin. Meanwhile the admin's phone streamed
   *better* with h3 enabled. h3 was re-enabled the same evening. **Lesson
   for network debugging on this LAN: before trusting any path-isolation
   probe, verify the probing machine's egress (VPN off, note the
   `remote_ip` the server sees).** The clean verification protocol for h3
   remains the checklist at the bottom of this doc; as of the re-enable,
   hairpin-UDP behavior is *unknown*, not known-bad.
2. **Source-based trust cannot cross the eero NAT** (SEC-1, 2026-07-16): the
   eero can launder internet traffic into the "trusted" 192.168.4.0/24 range,
   so an inner-firewall rule like "allow DNS from family LAN" is effectively
   "allow from internet" whenever a path exists. This is why split-horizon
   DNS served from OPNsense's WAN side is **permanently off the table** in
   this topology.
3. **The eero blocks two separate paths a MacBook would need to use in-lab
   DNS** (2026-05-08). Independent of the trust argument in #2 — these are
   mechanical, and each was confirmed before being worked around:
   - **Unicast frames to the OPNsense WAN MAC are silently dropped.** ARP
     resolves fine (the MacBook learns the `192.168.4.20` MAC), but unicast
     IP frames from WiFi clients to that MAC never arrive — confirmed with
     `tcpdump -i <nic0> host 192.168.4.20` on Proxmox showing nothing. Best
     guess: an eero anti-spoof / "unfamiliar device" filter reacting to the
     Proxmox VirtIO MAC OUI (`bc:24:11:…`) appearing on a wired path that
     never originates WiFi probes.
   - **Outbound `:53` from WiFi clients is intercepted regardless of
     destination IP.** With dnsmasq answering on Proxmox at
     `192.168.4.10:53`, `nc -vz 192.168.4.10 22` succeeded from the MacBook
     while `:53` to the same host was eaten. The eero enforces its own DNS
     path, presumably for its ad-blocking / family-filtering features.

   Tried and reverted, so nobody repeats them: a WAN firewall rule allowing
   `192.168.4.0/24 → 192.168.4.20:53` (rule was correct — Proxmox at `.4.10`
   could query through it, the MacBook at `.4.178` could not, per the first
   bullet); a dnsmasq forwarder on Proxmox (worked locally, unreachable from
   the MacBook per the second); and port-shifting dnsmasq to `:5354`, which
   would have dodged the interception via a macOS `/etc/resolver/` `port`
   directive but is eero-firmware-dependent and doesn't generalize past one
   device. SSH aliases sidestep both problems — alias resolution is local to
   the MacBook, and ProxyJump traffic is port 22, which the eero passes
   normally.

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
   internet-reachable. **Verify this step early** — consequence #3 above is
   the eero intercepting client `:53` regardless of destination. Setting the
   eero's *own* custom-DNS field is the supported path and should be exempt,
   but that is an assumption, not something measured. Confirm a WiFi client
   actually resolves via the Apps VM (`dig` a wildcard-override name, check
   the resolver's query log) before the rest of the migration depends on it.
5. Mac mini re-homed from OPT1 to the house LAN; update `OLLAMA_HOST`.
6. Bookkeeping: SSH config, RECOVERY/ADMIN_ACCESS/PROXMOX_MIGRATION docs.
   OPNsense VM parked powered-off (it is the fork-A option, not deleted).

Unaffected by design: certificates (DNS-01, no inbound dependency), USB
storage passthrough, GPU passthrough, all service data and compose configs.
Given up: the inner firewall between services and house LAN (acceptable —
every service already authenticates because it is internet-exposed; see
SECURITY_PASS auth map) and the OPNsense lab layer.

**Decision 2026-07-17: fork B is the intended direction but deferred** — it
is more impactful than a bugfix window.

## Sharing 443 with other boxes: Atoll

*Decided 2026-10-26 as "the switchboard", reframed 2026-10-29 as part of
Atoll. Live since 2026-10-30: the eero sends 443 to Atoll at `192.168.4.40`.*

This household serves more than one box's domains from its single public IPv4:
a second machine, running a separate project on its own domain and not part of
Coral Stack, joins Coral, and more may follow. Each box must keep its own TLS,
with nobody in the middle of encrypted traffic, and no project may host or
depend on another.

That is handled by **Atoll**, the household's platform, a separate project from
Coral Stack (private repos `atoll`, `switchboard` and `labnet`). A small VM on
the NUC's Proxmox runs two things:
- **The switchboard**, on 443:
  - **TCP:** it reads the hostname from the TLS ClientHello (the SNI, sent in
    the clear) and passes the still-encrypted connection to the box that owns
    that name, prefixed with a PROXY protocol v2 header carrying the visitor's
    address.
  - **UDP:** it passes all of it to Coral, in the kernel, unread and with the
    visitor's address intact.

  It holds no certificates, keys or credentials.
- **A lab network**, where other boxes get addresses and names without anyone
  touching the eero.

Coral is one tenant. It does not depend on Atoll: a household with only a Coral
box forwards 443 straight to it, as this one does today.

```
Internet ── eero ──443, TCP+UDP──▶ Atoll VM: switchboard
                                    ├ TCP ──SNI──▶ OPNsense WAN .20:443 → Apps VM Caddy
                                    │      └─SNI─▶ other boxes, on Atoll's lab network
                                    └ UDP ───────▶ OPNsense WAN .20:443 → Apps VM Caddy  (Coral's h3)
                                       replies: OPNsense ──reply-to──▶ Atoll VM → eero
```

**Where Coral sits: unchanged.** Coral stays on the house LAN behind its own
OPNsense, and the switchboard reaches it at OPNsense's WAN address. Moving
Coral into Atoll's lab network was considered and not chosen: it works today,
and its HTTP/3 path is the part most expensive to re-verify.

**Coral's HTTP/3 keeps UDP 443, with one more hop.** The eero forwards all of
443 to Atoll, so nothing depends on the eero splitting one port by protocol.
Atoll passes Coral's UDP through in the kernel without rewriting the source,
so Caddy still sees each visitor's address. Other boxes serve HTTP/3 on their
own ports, advertised with `Alt-Svc`: QUIC cannot be routed by hostname
without breaking connection migration and visitor addresses. The options
weighed, including routing UDP 443 to every box, are in the `switchboard`
README and Atoll's QUIC routing note.

**What changes for Coral: one Caddy setting, and `reply-to` in OPNsense.**

*`reply-to`, for UDP:* the eero accepts replies only from the address it
forwarded to, which is now Atoll's. Left alone, OPNsense would reply to HTTP/3
visitors straight through the eero, and those replies would be dropped. So
OPNsense sends its 443 replies back through Atoll. In OPNsense 26.x that takes
three settings, all live since 2026-10-30:

1. **A gateway for Atoll.** *System → Gateways → Configuration*: `ATOLL`, on
   WAN, `192.168.4.40`. Not an upstream gateway, and with monitoring off.
2. **A WAN rule that carries `reply-to`.** The forward in *Firewall → NAT →
   Destination NAT* ("Caddy HTTPS": WAN, TCP/UDP, HTTPS → `10.0.0.10:443`) has
   its Firewall rule set to **Manual**. With **Pass**, the forward admits
   traffic without consulting any WAN rule, so there is nowhere to put
   `reply-to`. The WAN rule "Caddy HTTPS (replies via Atoll)" passes TCP/UDP
   from any source to `10.0.0.10:443`, with *reply-to* `ATOLL` under its
   advanced options. Its *Gateway* field stays empty: that field reroutes the
   incoming traffic.
3. **Shared forwarding off.** *Firewall → Settings → Advanced*. It is on by
   default, and with it on, OPNsense applied `reply-to` only to replies
   addressed to the house LAN. Replies to internet visitors followed the
   default route to the eero and were dropped, so HTTP/3 from outside failed
   while every test from the LAN passed. This was measured on 2026-10-30,
   and turning the setting off fixed it.

*The Caddy setting, for TCP:* an SNI router opens its own
connection to each box, so without help every service would take the router
for the visitor. Synapse reads each visitor's address from Caddy
(`x_forwarded: true`) for its per-address limits and logs, and the h3
checklist below relies on the `remote_ip` Caddy sees. So Caddy now believes a
PROXY protocol header from `PROXY_PROTOCOL_FROM` (`.env`) and from nowhere else
([caddy/Caddyfile](../caddy/Caddyfile), global options). Unset, it trusts only
loopback and changes nothing. Measured locally on Caddy 2.11.7:
- Coral's own containers calling Caddy over the Docker network connect as
  before.
- A header forged by any other source is ignored, not believed.
- The trusted source may also connect without one.

The setting is generic. Any member whose box sits behind a shared front door
needs it, whether that's Atoll or a sibling site playing the relay role for a
CGNAT household (above). A member with one box and a plain port-forward leaves
it empty.

**Home devices** keep hairpinning through the eero, which works for every
domain today. The household resolver of the target topology still applies, but
in a multi-box household it belongs to Atoll, which serves every domain, rather
than to the Apps VM.

**The Phase-2 forks are not blocked.**
- **Fork B** changes the switchboard's Coral backend and its UDP pass-through
  from OPNsense's WAN to the Apps VM's new house-LAN address. The Apps VM must
  then send its 443 replies back through Atoll, the job `reply-to` does on
  OPNsense today. Fork B's step 4 (household DNS) moves to Atoll.
- **Fork A** gives OPNsense the public IP. Its NAT then sends TCP 443 to Atoll
  and UDP 443 straight to the Apps VM, and `reply-to` goes away.

### Coral's side of the rollout

The full runbook lives in the `atoll` and `switchboard` repos: the VM, the
eero, the preflight. Coral's part:

1. **Deploy the setting unset** (`git pull && ./setup.sh`). Inert: check all
   containers are healthy and the public path is unchanged.
2. **Trust Atoll** once its house-LAN address is reserved at the eero: add
   `PROXY_PROTOCOL_FROM=<Atoll's address>/32` to the Apps VM's `.env`
   (hand-edited, gitignored) and `docker compose up -d caddy`. Still inert:
   no traffic comes from that address yet.
3. **Prove it before the cutover.** From a LAN host, request
   `https://matrix.<BASE_DOMAIN>/_matrix/client/versions` through the
   switchboard (`curl --resolve …:443:<Atoll's address>`), then
   `docker logs --since 2m synapse | grep client/versions`. The line must show
   that LAN host's address, not Atoll's.
4. **Prove HTTP/3's return path on a spare port.** Atoll's preflight runs a
   QUIC handshake through Atoll to a temporary OPNsense forward (a spare lab
   port such as UDP 8463 → the Apps VM's 443) that has `reply-to` Atoll. It must complete. The live
   443 rule is untouched. **The test's source address must be off the house
   LAN.** A handshake from a LAN address passed on 2026-10-30 while Shared
   forwarding was still on, and the real path then failed. So run it from a
   LAN host to the household's *public* address: the eero's hairpin presents
   the public address as the source, which is off the LAN, like any visitor.
5. **The cutover, in one sitting:** the three OPNsense settings above, then the
   eero's 443 forward (TCP and UDP) moves from OPNsense to Atoll.
6. **After the cutover:**
   - From a phone on cellular, Pocket ID, Jellyfin and Element load. From the
     house, the same pages load through the hairpin.
   - HTTP/3 passes the verification bar below, with Caddy logging visitors'
     addresses, not Atoll's.

   Checked on 2026-10-30: every Coral hostname answered through the public
   address, both over HTTP/2 and over HTTP/3. An outside HTTP/3 checker
   (http3check.net) completed QUIC on every attempt, and Pocket ID logged the
   checker's own address.

**Rollback**, two steps, in this order:
1. **The eero:** point its 443 forward (TCP and UDP) back at OPNsense.
2. **OPNsense:** set "Caddy HTTPS" back to **Pass**, then Apply. That bypasses
   the WAN rule and its `reply-to`.

Step 2 is not optional. A rollback is most likely needed because Atoll is
down, and `reply-to` would keep sending Coral's replies to it. The `ATOLL`
gateway, the now-unused WAN rule and Shared forwarding can stay as they are.
`PROXY_PROTOCOL_FROM` can stay, since it
does nothing without traffic from that address, or go with one `.env` line and
a Caddy recreate. If it were ever lost while Atoll is live, nothing breaks: the
header is then ignored like any other source's, and services see Atoll's
address instead of visitors'.

## h3 verification bar

*(History: h3 was disabled 2026-07-17 on VPN-tainted evidence and re-enabled
the same evening — see the retraction above. It is currently ON. This
checklist is the bar for any future decision in either direction.)*

Before *disabling* h3 again (or claiming the hairpin drops UDP), or before
declaring h3 fully healthy, verify with clean instruments — **VPN off on the
probing machine, confirm the `remote_ip` Caddy sees matches the expected
path** — all of:

1. `curl --http3-only` against the service hostname from the LAN (true
   hairpin path).
2. Same test from a WAN vantage (cellular hotspot) — verifies the router's
   UDP forward for remote clients.
3. A freshly-installed iOS client (delete app first — Alt-Svc cache lives in
   the app container for 30 days) survives multi-track playback.
4. If any leg fails, prefer fixing the path (or the Phase-2 topology forks
   above, where h3 works by construction) over silently advertising a
   transport that blackholes for some clients.
