# Headscale (Phase 1.5)

Self-hosted Tailscale control plane. **Not yet deployed.** This doc captures the
direction so Phase 1 decisions stay compatible with it.

See [memory: Headscale candidate](../.claude/projects/-Users-dustindoan-Dev-personal-coral/memory/project_coralstack_headscale_candidate.md)
for the original framing.

## Why this is on the roadmap

The Phase 1 admin model (loopback bind + SSH tunneling — see
[ADMIN_ACCESS.md](ADMIN_ACCESS.md)) works for one admin doing infrequent
admin-from-laptop work. It gets clunky fast:

- **Mobile admin.** Want to check Proxmox from a phone? You're SSH-ing from a
  phone, then port-forwarding, then opening a browser. Doable. Painful.
- **Multi-service tunnels.** Six `-L` flags get unwieldy.
- **OPT1/VLAN routing.** The Mac mini lives on OPT1 (10.0.1.0/24); the laptop
  lives on the main eero LAN. Reaching admin UIs across that boundary today
  requires either OPNsense firewall rules or LAN-side bouncing through the NUC.
  Tailnet membership dissolves this — every joined device sees every other,
  routing-independent.
- **Future Mac mini work.** When lettabot lands on the Mac mini, its admin/UI
  endpoints have the same problem.

## Why Headscale and not the alternatives

| Option | Verdict |
| ------ | ------- |
| **Tailscale (SaaS control plane)** | Excellent UX but the coordination server is SaaS. Conflicts with the "own your infra" thesis. Free for personal use, but the dependency is real. |
| **OPNsense WireGuard** | Works, already on the box, but manual peer config per device, no MagicDNS, no auto-renewing keys. Higher ongoing toll. |
| **Headscale** | Self-hosted Tailscale-compatible control plane. Same tailscaled clients (open source) on every device, just pointed at our coordination server. Keeps the UX of Tailscale (MagicDNS, NAT punch, easy peer add) without the SaaS dependency. |
| **Just rely on SSH** | Where we are today. Doesn't scale to multi-device, multi-admin, mobile use. |

## Deployment shape (sketch)

Headscale is the *thing that lets you reach hosts*, so it can't live on a host
that's only reachable *via Headscale*. Chicken and egg. Two viable placements:

1. **On the OPNsense VM (or alongside it on the firewall layer).** Headscale
   listens on a public port (or via Caddy on `tailnet.<BASE_DOMAIN>`). The
   firewall is the most "always-up" thing in the rack and already terminates
   external traffic.
2. **On a dedicated tiny VM.** Resource overhead is trivial (~50MB RAM).
   Cleaner separation but more moving parts.

Default lean: **option 1** for Phase 1.5, **option 2** if Headscale grows
non-trivial config (ACLs, OIDC bridge to Pocket ID, etc.) in Phase 2.

## What changes in this repo

Mostly nothing in Phase 1.5 — the admin-bind rule already accommodates Headscale.
The migration is:

1. Deploy Headscale (in OPNsense VM or new VM, not in `coralstack-infra` compose)
2. Install `tailscale` on the NUC, the Mac mini, the laptop, the phone
3. `tailscale up --login-server=https://tailnet.<BASE_DOMAIN>` on each
4. Admin UIs that were loopback-only need their bind updated to also listen on
   `tailscale0`. Two patterns:
   - **Per-service:** add `tailscale0` IP to the published-port host binding
   - **Network-wide:** put admin services behind a single internal reverse proxy
     that itself binds to `tailscale0`
5. Update [ADMIN_ACCESS.md registry](ADMIN_ACCESS.md#registry-of-admin-uis) with
   the MagicDNS hostnames

The loopback-only rule for *fresh* admin services stays — it's a safe default.
The Headscale exposure is additive.

## Open questions

- **OIDC bridge to Pocket ID.** Headscale has experimental OIDC. Worth wiring
  to Pocket ID once Phase 2 brings a second admin — gives them tailnet access
  via passkey rather than pre-shared auth keys. Until then, single-user
  pre-auth-key model is fine.
- **Subnet router for member-side reach.** Members today reach services via
  public DNS + Caddy. There's a *future* scenario where members are also on
  the tailnet (e.g., a member's Mac running puddle/duckling wants to push
  files to Ente without going through public DNS). Probably not until Phase 2+.
- **Backup / DR for Headscale itself.** If Headscale's DB dies, every device
  needs re-enrollment. Belongs in the Phase 1.5 backup work, not as a separate
  question.

## When to actually do this

Trigger: **the next time you find yourself running more than two `ssh -L` flags
in one command, OR the first time you want to admin something from a phone.**
Until then, Phase 1 is fine.

**TRIGGER FIRED 2026-08-10.** The working admin command is now seven forwards:

```bash
ssh -L 8989:localhost:8989 -L 7878:localhost:7878 -L 9696:localhost:9696 \
    -L 8090:localhost:8090 -L 3000:localhost:3000 -L 9443:localhost:9443 \
    -L 9191:localhost:9191 coralstack-apps
```

---

## Hand-off — start here next session

State as of 2026-08-10. Layer 1 of the admin front door
([ROADMAP](ROADMAP.md) Phase 1.5) is done: Homepage is deployed and lists every
service. This is layer 2. Layer 3 (forward_auth) stays deferred.

### Decision to make first

**Where Headscale runs** — the sketch above leans OPNsense VM (option 1) but it
was written before the apps VM filled up with services. Settle this before
touching anything, because it determines how the control plane is reachable.

Related and unresolved: Headscale needs a **publicly reachable endpoint** for
clients to coordinate against. The box sits behind eero double-NAT with a single
443 forward (see [NETWORK_TOPOLOGY.md](NETWORK_TOPOLOGY.md) and the
product-topology memory). Options: a Caddy route on `tailnet.<BASE_DOMAIN>`, or
a second forwarded port. Decide alongside placement.

**Also expect to need a DERP relay.** Double-NAT (eero in front of OPNsense) is
exactly the shape where direct NAT punching fails and traffic falls back to a
relay. Tailscale's public DERP servers work with Headscale out of the box, but
that quietly reintroduces a third-party dependency the whole exercise is meant
to avoid — self-hosting a DERP is the consistent choice, and it's extra work.
Worth deciding deliberately rather than discovering.

### The wrinkle the sketch above doesn't cover

Step 4 says admin UIs "need their bind updated to also listen on `tailscale0`".
That's still right, but note **how** it works for the VPN-netns services.

Sonarr, Radarr, Prowlarr and qBittorrent have no network identity of their own —
they share `arr-vpn`'s namespace, and *it* publishes their ports. Same for
Dispatcharr via `dispatcharr-vpn`. Fortunately the `ports:` mapping is a
**host-side** binding, so this does *not* require touching Gluetun's
kill-switch or the netns. It's just:

```yaml
ports:
  - "127.0.0.1:8989:8989"        # keep — loopback stays working
  - "${TAILSCALE_IP}:8989:8989"  # add
```

Which means a new `TAILSCALE_IP` in the root `.env` (setup.sh should resolve it,
since it's assigned by Headscale and differs per host). Services needing this:

| Service | Port | Compose file |
| ------- | ---- | ------------ |
| Sonarr / Radarr / Prowlarr / qBittorrent | 8989 / 7878 / 9696 / 8090 | [services/arr](../services/arr/docker-compose.yml) (all on `arr-vpn`) |
| Dispatcharr | 9191 | [services/dispatcharr](../services/dispatcharr/docker-compose.yml) (on `dispatcharr-vpn`) |
| Homepage | 3000 | [services/homepage](../services/homepage/docker-compose.yml) |
| Portainer | 9443 | [services/portainer](../services/portainer/docker-compose.yml) |
| Admin panel | 9090 | [services/admin-panel](../services/admin-panel/docker-compose.yml) (not yet deployed) |

### MagicDNS names hosts, not services — the registry oversells this

The [registry](ADMIN_ACCESS.md#registry-of-admin-uis)'s "Phase 1.5 (Headscale)"
column lists `home.nuc`, `sonarr.nuc`, `tv.nuc` and so on. **Those don't come
free with Headscale.** MagicDNS assigns one name per *host*, so the apps VM gets
a single name and everything on it stays port-addressed. `proxmox.nuc` and
`opnsense.fw` are fine — separate machines — but the rest are all the same box.

Two stages, and the first is the one that matters:

| | What you get | Work |
| - | ------------ | ---- |
| **A** | `http://coralstack-apps:3000` etc. from any enrolled device | just the tailnet binding above — **this is what kills the 7-forward command** |
| **B** | `https://home.…` per-service names | + Headscale `dns.extra_records` mapping each name to the tailnet IP, + a Caddy listener on `tailscale0` doing name-based routing |

Do A, live with it, and only do B if the port numbers actually annoy you.

If you do B: **don't use `.nuc`.** It isn't a real domain, so it needs Caddy's
internal CA and that root installed on every device. Use real subdomains
instead (e.g. `home.internal.<BASE_DOMAIN>`) pointed at the tailnet IP via
`extra_records` — the existing Cloudflare DNS-01 setup then issues genuinely
trusted certs, with no CA distribution and no browser warnings, and the names
never resolve publicly.

### ExpressVPN on the Mac will fight the Tailscale client

Not a blocker, but it's the one place these collide. ExpressVPN in this stack
runs *inside* Gluetun containers (`arr-vpn`, `dispatcharr-vpn`), confined to
those namespaces — it never touches the apps VM's routing table, so the tailnet
interface there is unaffected.

Your **laptop** is the conflict surface: two VPN clients both want the default
route and the DNS resolver, and ExpressVPN is aggressive about taking both. The
symptom is the tailnet silently failing to resolve while ExpressVPN is up. Fix
is ExpressVPN's split tunnelling, excluding the tailnet range.

(For the record: the move away from tailnet-only was *not* caused by this. It
was member UX — family shouldn't need a VPN client for Jellyfin — plus
Tailscale-the-service's external IdP requirement and SaaS control plane. Those
reasons are why the replacement is self-hosted Headscale, and none of them
apply to admin-only access.)

### Homepage follow-up (cheap, do it last)

Once MagicDNS names exist, [services/homepage/config/services.yaml](../services/homepage/config/services.yaml)
needs its admin-plane `href` values changed from `http://localhost:<port>` to the
MagicDNS name — one line per service, and the file is committed so it deploys by
git pull. Leave `siteMonitor` alone: those are container-network URLs and are
unaffected.

Also add the MagicDNS hostname to `HOMEPAGE_ALLOWED_HOSTS` in
[services/homepage/docker-compose.yml](../services/homepage/docker-compose.yml) —
it currently lists `home.nuc` as a placeholder, which must be made to match the
real name or Homepage will reject the requests.

### Definition of done

- Every admin UI in the [registry](ADMIN_ACCESS.md#registry-of-admin-uis)
  reachable by MagicDNS name from the laptop **and** the phone, with no `ssh -L`
- Loopback bindings still work (the rule is additive, not replaced)
- Homepage links go to MagicDNS names
- Registry table updated with the new names
- Headscale's DB included in the backup set — losing it means re-enrolling every
  device ([BACKUPS.md](BACKUPS.md))
