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
  the tailnet (e.g., a member's Mac running coralstack-migrator wants to push
  files to Ente without going through public DNS). Probably not until Phase 2+.
- **Backup / DR for Headscale itself.** If Headscale's DB dies, every device
  needs re-enrollment. Belongs in the Phase 1.5 backup work, not as a separate
  question.

## When to actually do this

Trigger: **the next time you find yourself running more than two `ssh -L` flags
in one command, OR the first time you want to admin something from a phone.**
Until then, Phase 1 is fine.
