# Pre-launch security pass — 2026-07-15

A pre-soft-launch review of the externally reachable surface. This is a
point-in-time snapshot, not a continuous control; re-run it before the public
link, after any edge/firewall change, **and whenever a new public vhost is
added to the Caddyfile** — that last trigger was added after SEC-2, which is
exactly the drift a point-in-time audit can't catch on its own. Scope: what an
attacker on the public internet can see and reach, plus a repo-history secrets
audit.

## Summary

| Area | Result |
| --- | --- |
| Git history secrets | ✅ **Clean** — `gitleaks` over all 57 commits, no leaks. |
| Published container ports | ✅ Only Caddy `443` (+ `443/udp` HTTP/3). Dispatcharr bound to `127.0.0.1:9191`. |
| Per-service auth | ⚠️ True for every service audited on 2026-07-15, but **not automatic for services added later** — see [SEC-2](#sec-2-medium--unclaimed-first-run-setup-wizard-on-a-public-vhost). An *unclaimed* service doesn't self-authenticate, it self-enrols. |
| WAN port scan | ✅ **SEC-1 remediated + re-verified from off-net 2026-07-16** — see the finding's remediation log. |
| Vaultwarden signups | ✅ `SIGNUPS_ALLOWED=false`, invitation-only. |

## Findings

### SEC-1 (HIGH) — Open recursive DNS resolver on the WAN IP

**`53/tcp` and `53/udp` on `38.175.158.9` answer recursive queries from the
public internet.** Verified from an external host: a query for `google.com`
returned six A records with the `ra` (recursion-available) flag set.

**Why it matters.** Open resolvers are abused for DNS amplification/reflection
DDoS (a spoofed-source query yields a much larger response aimed at a victim).
Beyond enabling attacks on third parties, it invites the IP onto abuse
blocklists — which for a single-IP residential deployment can take *every*
CoralStack service offline. It also leaks that a resolver (likely OPNsense
Unbound) sits here and reveals cache contents via timing.

**Almost certainly** OPNsense's Unbound listening on *all* interfaces including
WAN, rather than LAN-only. This lines up with the Phase-1 single-NIC bridge-mode
topology (see [infrastructure architecture memory]) where interface separation
is already a documented compromise.

**Remediation (admin, via the OPNsense GUI tunnel — not automatable from here):**
1. **Services → Unbound DNS → General → Network Interfaces:** restrict listening
   to LAN/OPT interfaces only; **remove WAN** (and `all`).
2. Belt-and-suspenders: **Services → Unbound → Access Lists** — allow only the
   internal ranges (`10.0.0.0/24`, `10.0.1.0/24`, etc.), default-deny.
3. Confirm no WAN firewall rule forwards `53` to the apps VM / Unbound.
4. **Verify from off-net:** `dig @38.175.158.9 google.com` should now time out
   or `REFUSED`. Re-run `nmap -Pn -p53 38.175.158.9`.

Until fixed, this is the top item ahead of any public link — it's remotely
abusable with zero credentials.

**Remediation log — 2026-07-16, CLOSED.** All three layers applied, root cause
identified, verified from off-net:

1. **Listener removed:** Unbound Network Interfaces restricted to internal
   interfaces; WAN removed. Internal resolution verified intact from the apps
   VM afterward (`dig @10.0.0.1` answered).
2. **ACLs added:** Unbound Access Lists now allow only the internal ranges;
   unmatched sources are refused even if the listener list ever regresses.
3. **Root cause found:** a hand-added WAN pass rule — *"Allow DNS from family
   LAN to OPNsense Unbound"* (TCP/UDP 53, source `192.168.4.0/24` →
   This Firewall). The source restriction **looked** safe but wasn't: OPNsense
   sits behind the eero's NAT, and traffic the eero sends toward OPNsense can
   arrive source-rewritten into the "trusted" `192.168.4.0/24` range — so the
   rule effectively passed internet-originated queries. **Lesson for host
   admins: behind an upstream NAT, source-based trust in the inner firewall is
   unsound — the outer NAT can launder any source into your trusted range.**
   The rule was not part of any documented design (nothing in the runbooks or
   the deployed stack depends on it) and is disabled (verified nothing on the
   household LAN relied on it: family devices resolve via the eero/ISP path, and
   the media hairpin never touches port 53).
4. **Upstream checked:** the eero forwards only `443` to the OPNsense WAN IP —
   no 53 forward, no DMZ.
5. **Off-net verification:** `dig @38.175.158.9 google.com` from an external
   vantage point now **times out** (previously: six A records with `ra` set).

### SEC-2 (MEDIUM) — Unclaimed first-run setup wizard on a public vhost

**`status.<BASE_DOMAIN>` served Uptime Kuma's unclaimed setup wizard to the
public internet.** Discovered 2026-08-25 when the admin opened the URL and was
offered account creation rather than a login. Kuma had been deployed some time
earlier and never configured.

**Why it matters.** Anyone who found the hostname could have created the admin
account and owned the monitoring instance. Blast radius is bounded but real:
Kuma sits on the `coralstack` docker network and can issue HTTP probes to every
service by container name, so a claimant gets a map of the internal topology
plus a probe primitive against internal addresses. It grants no shell, no data,
and nothing in the vaults.

**Not exploited.** The setup wizard still being offered is itself the proof —
had anyone claimed it, the page would have shown a login form instead.

**Remediation — 2026-08-25, CLOSED.** Admin account created immediately, with a
generated password stored in Vaultwarden as a Tier-2 secret. Verify
`Settings → Security → Disable Authentication` stays **off**; that toggle
deliberately reopens this exact hole.

#### The class, which matters more than the incident

This is not a Kuma bug. It's a property of the deploy pattern:

> bring the container up → Caddy routes it publicly → configure it later

Every service with a first-run setup wizard has a **claim window** sized by how
long "later" lasts. Jellyfin, Open WebUI and Pocket ID all share the property —
each one's first account becomes an admin. They're fine only because daily use
claimed them within minutes of deployment. That was circumstance, not design.

It also shows how the audit's own summary went stale: "every web-exposed service
self-authenticates" was true when it was written and became false the moment a
new vhost shipped, with nothing to notice. Hence the new re-run trigger at the
top of this document.

**The rule:** a new public vhost is **claimed in the same session it is
deployed**, or it stays loopback-bound until it is. Added to the
[new-service checklist](ADMIN_ACCESS.md#checklist-for-new-public-plane-services).

## Auth-coverage map (Caddy edge)

There is intentionally **no `forward_auth` SSO gate** in front of the services
today (that's the deferred admin-front-door layer — see the admin-dashboard
memory / ROADMAP). Instead every exposed vhost authenticates itself:

| Route | Backend | Auth |
| --- | --- | --- |
| `{domain}` | Caddy `respond` | None — static string, no data. Fine. |
| `id.` | Pocket ID | Own login (the IdP itself). |
| `vault.` | Vaultwarden | Own login, SSO'd via Pocket ID. |
| `photos*.` | Ente web/museum/accounts/albums | Ente account + E2E encryption. |
| `photos-storage.` | MinIO | AWS SigV4 presigned URLs only (museum-issued). |
| `media.` | Jellyfin | Own login + SSO-Auth plugin. |
| `ai.` | Open WebUI | Own login, OIDC via Pocket ID. |
| `status.` | Uptime Kuma | Status page public **by design**; admin UI behind Kuma's own login. Was unauthenticated until claimed — see [SEC-2](#sec-2-medium--unclaimed-first-run-setup-wizard-on-a-public-vhost). No native SSO exists for it (see [ADMIN_ACCESS](ADMIN_ACCESS.md#reach-mechanisms-phase-2--shared-admin)). |
| *(none)* | Dispatcharr | **Not exposed via Caddy** — bound to `127.0.0.1:9191`. |

**Assessment:** acceptable for launch. No service is exposed without
authentication. The absence of a unifying SSO gate is a defense-in-depth *nice
to have* (one login wall, uniform session policy), not a hole — it's tracked as
the admin front-door work, not a launch blocker.

## For the user to decide (not a security control, a positioning call)

**Dispatcharr's place in the public story.** It is not publicly exposed (good,
security-wise), but the repo ships a Gluetun VPN-egress config whose purpose is
to hide the residential IP for IPTV traffic — see the Dispatcharr-VPN memory.
That's fine for a private stack; on a repo you're *publicly promoting to co-ops*
it reads differently (legally-gray, and it's the one service with a
concealment-shaped design). Options, roughly:
- Keep it, document it explicitly as an out-of-scope personal add-on, not part
  of the CoralStack value proposition.
- Move it to a private overlay repo / compose file, out of the public repo.
- Leave as-is and accept it's part of the story.

This isn't mine to decide — flagging it so the public-site copy (gate #5) and
the repo's public framing are a deliberate choice, not an accident.

## Method (repeatable)

```bash
gitleaks git . --no-banner                       # history secrets
grep -rn "ports:" -A1 services/*/docker-compose.yml docker-compose.yml
nmap -Pn -T4 --top-ports 1000 <WAN_IP>           # external port surface
dig @<WAN_IP> google.com                          # open-resolver check (expect REFUSED/timeout)

# Vhost drift: every public hostname Caddy serves should have a row in the
# auth-coverage map above, and each should answer with a LOGIN, not a setup wizard.
grep -oE '^[a-z0-9.*{$-]+\{' caddy/Caddyfile
```
