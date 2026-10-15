# Monitor definitions

The CoralStack monitor set, as code. `setup.sh` renders this directory into
`${DATA_PATH}/autokuma/monitors`, where AutoKuma reads it:

- `*.toml` — copied as-is. No secrets, safe in a public repo.
- `*.toml.template` — `envsubst`'d with the push tokens from
  `services/autokuma/.env`. **Never commit a rendered push token.**

Filename (minus extension) is the AutoKuma ID and must be stable — renaming a
file makes AutoKuma treat it as a new monitor and orphan the old one.

Full property reference: <https://autokuma.bigboot.dev/dev/>

## ⚠️ `resend_interval` IS A NO-OP ON AUTOKUMA 2.0.0 — SET IT BY HAND

**Measured on the box 2026-10-15.** AutoKuma 2.0.0 (what `services/autokuma/
docker-compose.yml` pins) applies a changed `interval` to an existing push
monitor **within 10 seconds**, and silently ignores `resend_interval` — no
error, no warning, no log line. Upstream confirms it: the stable `:2` image
drops `resend_interval` for TCP-port and push monitors, and it only becomes a
shared monitor field in 2.1.0-rc.2. Every monitor in this directory is
`type = "push"`, so **every `resend_interval` below is currently aspirational.**

Until AutoKuma ships ≥2.1 stable, these values have to be set in Kuma's UI by
hand: *Edit monitor → "Resend Notification if Down X times"*. They persist
there, because AutoKuma does not manage the field and so will not revert them —
proven in the same test, which saw it rewrite `interval` while leaving
`resend_interval` at 0.

`config:recommended` sets `ignoreUnstable`, so Renovate will not offer the
2.1.0 release candidate and will propose 2.1.x once it is stable. Delete this
section when that lands and the values start applying themselves.

## `resend_interval` — the unit is down BEATS, not minutes

Kuma notifies on state **changes**. A monitor with `resend_interval = 0` — the
default, and what all five push monitors shipped with — alerts once when a
condition appears and then stays silent for as long as it stays true. For a
dead-man's-switch watching something that cannot self-heal, that is a single
notification and then nothing.

`resend_interval = N` re-sends after **N consecutive down beats**. Read from
Kuma 2.4.0's own source (`server/model/monitor.js` and
`server/routers/api-router.js`, which implement it identically for polled and
pushed monitors): each down beat does `++downCount`, and when
`downCount >= resendInterval` it notifies again and resets the counter. It is a
count of beats. It is not a duration, and it is not minutes.

So the wall-clock cadence depends on **which failure mode you are in**, because
the two produce down beats at different rates:

| State | What produces a down beat | Cadence of `N = 1` |
| --- | --- | --- |
| Checker running, reporting a finding | the script's own `status=down` push | once per check — **daily**, for all five |
| Checker stopped | Kuma's own "no heartbeat in the time window" | once per `interval` — **every 48h** |

Both were observed on monitor #12: daily pushes carrying the real message,
interleaved with 48-hourly `No heartbeat in the time window` beats exactly
`interval` apart.

Every producer in this repo runs daily — backup 03:15, drift 06:10, SMART apps
VM 06:20, Ollama reconcile 06:35, SMART host 06:50 — so **`N` reads as roughly
"days" while the checker is alive**, and doubles if it has died. Pick `N` on
how fast the cost of ignoring the finding grows, not on how bad it sounds:

| Monitor | `N` | Why |
| --- | --- | --- |
| SMART (apps VM), SMART (Proxmox host) | 1 | Closing remediation window — get the data off |
| Nightly backup | 1 | Each silent night is another day of one-copy-only data |
| Deploy drift (apps VM) | 3 | Stable condition, often a legitimate live-incident state |
| Ollama reconcile (Mac mini) | 7 | Standing homework on the host where a bad update costs nothing |

AutoKuma reconciles this field onto monitors that **already exist** — it is not
create-only. See the note in [MONITORING.md](../../../docs/MONITORING.md) for
the mechanism and for the one-line DB check to run after deploying a change
here.
