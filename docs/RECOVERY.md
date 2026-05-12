# Power-loss recovery

How to verify the coralstack returns from a full power outage with no human intervention, and the pre-flight checks that make that possible.

This is a runbook for the **Phase 1 Proxmox topology** (see [PROXMOX_MIGRATION.md](PROXMOX_MIGRATION.md) for the full architecture). The boot chain is:

```
AC restored
  │
  ├─► eero boots first (~1 min)
  ├─► Mac mini boots → auto-login → Ollama menu bar app starts
  └─► NUC boots → Proxmox → OPNsense VM → (45s delay) → Apps VM → Docker → containers
```

Anything in this chain that doesn't auto-start breaks the recovery. The pre-flight checks below configure each layer; the test at the end verifies the whole chain.

## Pre-flight: NUC

### BIOS

Reboot the NUC, hit F2 at the splash screen.

| Setting                                                 | Value      | Why                                                                     |
| ------------------------------------------------------- | ---------- | ----------------------------------------------------------------------- |
| Advanced → Power → **After Power Failure**              | `Power On` | BIOS auto-boots when AC returns; without this, NUC waits for power button |
| Boot order                                              | Proxmox disk first | Should be default; verify after firmware updates                |

Save + exit.

### Proxmox VM start-at-boot

In the Proxmox web UI, for each VM:

**Options → Start at boot:** `Yes`
**Options → Start/Shutdown order:**

| VM       | Order | Up delay (sec) |
| -------- | ----- | -------------- |
| OPNsense | `1`   | `0`            |
| Apps VM  | `2`   | `45`           |

The 45s delay on the Apps VM lets OPNsense finish booting (interfaces up, DHCP service running) before the Apps VM tries to grab an IP. Bump to 90s if DHCP timing flakes during testing.

### Apps VM: Docker enabled

SSH into the Apps VM (10.0.0.10):

```bash
systemctl is-enabled docker        # expect: enabled
```

If `disabled`, fix it:
```bash
sudo systemctl enable docker
```

Containers already have `restart: unless-stopped`, so Docker starting at boot = containers starting at boot.

## Pre-flight: Mac mini

| Setting                                                            | Where                                                | Why                                       |
| ------------------------------------------------------------------ | ---------------------------------------------------- | ----------------------------------------- |
| **Automatically log in as** `<admin user>`                         | System Settings → Users & Groups                     | Ollama is a user-level menu bar app; needs a logged-in session |
| **Open at Login** includes Ollama                                  | System Settings → General → Login Items              | Starts Ollama after auto-login            |
| **Start up automatically after a power failure**                   | System Settings → Energy                             | Mirrors the NUC's BIOS setting            |
| `OLLAMA_HOST=0.0.0.0:11434`                                        | `launchctl setenv OLLAMA_HOST "0.0.0.0:11434"`       | Default loopback-only binding isn't reachable from the Apps VM |

After setting `OLLAMA_HOST`, quit + relaunch Ollama from the menu bar (the env var is read at start). Verify from the Apps VM:

```bash
curl -fsS http://10.0.1.10:11434/api/tags
```

Should return a JSON list of installed models.

## Pre-flight: eero

Set a **DHCP reservation** for the NUC's WAN-side MAC address so the NUC always lands on the same eero LAN IP (`192.168.4.20` per the architecture). Without a reservation, eero might hand it a different IP after reboot, which doesn't break anything immediately but invalidates the `192.168.4.20 → OPNsense WAN` port-forward.

## The test

### Variant 1: graceful shutdown (software-side only)

Tests the Proxmox VM auto-start chain and the apps Docker chain, but **not** the BIOS auto-power-on setting (a clean halt is a deliberate event; BIOS keeps the box off until power button press).

```bash
# SSH into Proxmox host (NUC management IP), NOT via OPNsense — see "Gotchas" below
sudo shutdown -h now
```

Wait for the NUC to halt (Proxmox gracefully stops VMs in reverse boot order). Press the power button.

### Variant 2: full power loss (the real test)

Tests the entire chain including BIOS auto-power-on.

```
1. Physically unplug the NUC power cable.
2. Wait 60 seconds (long enough that BIOS treats this as an unexpected AC loss, not a brownout).
3. Plug back in. Don't touch the power button.
```

NUC should auto-boot. If it doesn't, BIOS "After Power Failure" isn't set correctly — re-check.

### Variant 3: whole-house cold start (the apocalyptic test)

Trip the breaker (or unplug eero + NUC + Mac mini). Wait 60s. Restore power.

This is the actually-realistic failure mode: power outage at the apartment. Worth doing **once** before the second household onboards — gives you empirical confidence that the stack is self-healing, not just hopefully self-healing.

## Verification

Run these from **outside the failure domain**: laptop on eero's WiFi directly (not coralstack network), or LTE tethering if you're being thorough. If your laptop is routed through OPNsense, you can't tell whether you're back.

```bash
# 1. OPNsense's LAN interface (routes everything coralstack)
until ping -c1 -W2 10.0.0.1 >/dev/null 2>&1; do echo "waiting for OPNsense..."; sleep 5; done && echo "OPNsense up"

# 2. Public-facing TLS endpoint (Caddy + apps VM both up)
until curl -ksS -o /dev/null -w "%{http_code}\n" https://id.<BASE_DOMAIN> | grep -q "200\|302"; do sleep 5; done && echo "Pocket ID up"

# 3. Ollama via OPT1 path (Mac mini back, OPT1 routing intact)
curl -fsS http://10.0.1.10:11434/api/tags
```

Full cold boot is realistically **3-5 minutes** end-to-end. Don't worry before 5 minutes have elapsed.

## Per-service smoke checks

Containers being up isn't the same as services being healthy. After the network probes pass, spot-check each service:

| Service     | Smoke check                                                                                 |
| ----------- | ------------------------------------------------------------------------------------------- |
| Pocket ID   | Load `https://id.<BASE_DOMAIN>` → login page renders (not a 502)                            |
| Vaultwarden | Unlock vault via Bitwarden desktop → entries decrypt (proves SSO + master passphrase work)  |
| Jellyfin    | Sign in via SSO → play a media file (proves SSO + storage mount both work)                  |
| Ente Photos | Open mobile app → photo library loads (proves museum + postgres + MinIO storage all up)     |
| Open WebUI  | Sign in via SSO → send a chat → response streams (proves the full Pocket ID + OPT1 + Ollama chain) |

If any one fails, the layer that failed is usually obvious from which service broke — e.g., Open WebUI sign-in works but chat times out → Ollama side. Jellyfin loads but media won't play → storage mount.

## Observed recovery times

Capture these the first time you run a real test. Useful both as a smoke baseline and as the eventual input for the lettabot heartbeat work.

| Event                           | Time from AC restored | Date observed | Notes |
| ------------------------------- | --------------------- | ------------- | ----- |
| NUC POST complete               |                       |               |       |
| Proxmox host pingable           |                       |               |       |
| OPNsense LAN pingable (10.0.0.1)|                       |               |       |
| Apps VM Docker started          |                       |               |       |
| Caddy serving TLS               |                       |               |       |
| Pocket ID responding            |                       |               |       |
| Mac mini Ollama responding      |                       |               |       |
| End-to-end (Open WebUI chat works) |                    |               |       |

## Gotchas

- **Time drift after cold boot.** If the NUC's CMOS battery is dead, the clock resets at every boot and TLS handshakes fail until NTP syncs. Symptom: Caddy logs show certificate validation errors right after boot, then resolves on its own ~1-2 min later. Easy fix is replace the CR2032 in the NUC.
- **Caddy + ACME on cold boot.** Existing certs are cached in `${DATA_PATH}/caddy/data`, so Caddy serves them immediately without needing outbound internet. Renewals happen in the background once outbound is restored. No member-facing impact even if the cold boot happens during a renewal window.
- **SSH path during graceful shutdown.** If you're SSH'd into the NUC over a path that traverses OPNsense, your session will freeze mid-shutdown when OPNsense gets halted. The halt still completes (it's local on the NUC), but you lose visibility. SSH directly to the NUC's management IP on eero LAN — not via the coralstack network — when running `shutdown`.
- **Ente museum waiting on postgres.** Museum has retry-on-startup logic for postgres, so a cold boot should resolve itself. If museum logs show "connection refused" loops for more than ~60s after postgres is up, restart museum manually: `docker compose restart ente-museum`. Hasn't happened in practice but worth knowing.
- **eero DHCP after whole-house power loss.** If eero hands the NUC's WAN a different IP than before, OPNsense WAN still works but anything pinned to the old IP breaks. Mitigation: DHCP reservation on eero (see pre-flight above).

## When to re-run this test

- **Before onboarding household 2.** Last point at which "self-healing recovery" can still be aspirational rather than verified.
- **After any hardware change** to the NUC, Mac mini, or eero. BIOS settings can reset, login-at-boot can be cleared, DHCP reservations can be lost.
- **After upgrading Proxmox major versions.** VM start-at-boot config has historically been stable across upgrades, but worth re-verifying.
- **Annually as a habit**, even if nothing changed. Cheap insurance.
