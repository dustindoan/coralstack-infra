# Music acquisition & ingest — purchase → library → Jellyfin

> **Status:** 💭 exploration / hand-off doc. No code yet. This frames the
> problem, the options, and the decisions a future session needs to make *with
> the admin* before building. It is the substance behind
> [LAUNCH_BLOCKERS](LAUNCH_BLOCKERS.md) gate #2 (music) and a future member-side
> music import tool (home TBD — it was planned as coralstack-migrator's `media`
> module, but that repo is archived).

## The north star

> "Buy the new Mumford & Sons album on-the-go, and have it appear in my
> collection and be playable through a Jellyfin music app automatically and
> near-instantaneously."

Two distinct things hide in gate #2:
1. **Migration** — get the admin's *existing* library onto the stack (one-time;
   belongs in a member-side import tool, mirroring the photo path — home TBD now
   that coralstack-migrator is archived).
2. **Acquisition** — an ongoing *buy → owned → playable* pipeline. **This doc is
   mostly about #2**, which is the more interesting (and more product-shaped)
   problem and the one the admin is excited about.

## Current state (verified 2026-06-24)

- Jellyfin mounts the library **read-only**: `${STORAGE_PATH}/music:/media/music:ro`
  (see [services/jellyfin/docker-compose.yml](../services/jellyfin/docker-compose.yml)).
- **beets is now built as a container** (`services/music/`, 2026-07-15) — the
  earlier "managed by beets on the host" comments were aspirational and have
  been corrected. Decision resolved in favour of containerized (reproducible,
  fits the stack). See [What's built](#whats-built-2026-07-15).
- Acquisition guidance today is just a note in gate #2 (Bandcamp, Qobuz, rip CDs).
- Music is **excluded from offsite backup by default** (`BACKUP_EXCLUDES`,
  see [BACKUPS.md](BACKUPS.md)) — it's treated as re-acquirable. That assumption
  should be revisited if purchased-and-owned music becomes the norm: a purchase
  the admin paid for and can't trivially re-download *is* worth backing up.

## The pipeline (four stages)

```
  [1 Purchase]  →  [2 Acquire]  →  [3 Ingest]  →  [4 Surface]
   buy a DRM-       pull DRM-free    beets: tag,    Jellyfin sees
   free album       files to the     organize,      it & it plays
   (mobile)         server           fetch art      in the app
```

Stages 3–4 are **deterministic and well-trodden** (beets + Jellyfin is a known
stack). Stages 1–2 — *getting the just-purchased bytes onto the server from a
phone, fast* — are the hard, store-specific part and where the real design work is.

## The central tension: "buy & own" vs auto-grab

There are two philosophies, and the choice defines the project:

| | Buy & own (recommended) | Lidarr-style auto-grab |
|---|---|---|
| How | Purchase DRM-free from a store, ingest the files | Lidarr monitors artists, auto-downloads new releases from indexers (usenet/torrent) |
| "New album appears automatically" | Needs a purchase + fetch step | Yes, fully automatic |
| Ethics / co-op values | Artist-supporting, legitimate, on-brand for a sovereignty co-op | Piracy-adjacent; hard to reconcile with the co-op's values pitch |
| Effort | Store-specific acquisition glue | Mature tooling (Lidarr) but pointed at grey sources |

**Recommendation: the buy-&-own path.** It's the only one consistent with how
CoralStack positions itself. Lidarr is worth understanding as prior art (its
*monitor-artist → auto-ingest* UX is exactly the desired feel) but its default
acquisition source is the wrong fit. The interesting product question is whether
we can give the **Lidarr feel on a buy-&-own backend**.

## Where to buy (DRM-free matters)

The library only works if files are **DRM-free** and downloadable. That rules out
streaming/locker services (Apple Music, Spotify, Amazon Music streaming).

| Store | Catalog | Format | Clean automation? | Notes |
|---|---|---|---|---|
| **Bandcamp** | Indie-heavy; **patchy for major labels** | MP3/FLAC, DRM-free | ✅ **Yes, server-native** — [BandcampSync](https://github.com/meeb/bandcampsync) is a Docker container that downloads **your own purchases** (FLAC, checkpointed so it only fetches new buys); official OAuth API also exists | Most artist-direct / co-op-aligned, and the **only store where the full "buy → auto-appears" pipeline is both clean and already-built.** The Mumford & Sons example likely *isn't* here (major label). |
| **Qobuz** | Broad incl. major labels (Mumford & Sons ✓); Hi-Res | FLAC up to hi-res, DRM-free purchase | ✅ **Verified buildable (2026-07-15)** — the purchases-API path passed a live end-to-end probe (token auth → purchase enumeration → full hi-res file granted); see [Qobuz acquisition](#qobuz-acquisition--build-options-verified-2026-06-25). GUI Downloader remains the desktop-only fallback; `qobuz-dl`/streamrip default to **stream-ripping (rejected)** | Best catalog for the mainstream example. Fetcher is a small build on a proven path; token lifetime is the remaining operational unknown. |
| ~~**7digital**~~ | ~~Broad, major labels~~ | — | ❌ **Ruled out** | Acquired by Songtradr → folded into **MassiveMusic** (B2B-only, June 2025). API moved to `docs.massivemusic.com`, now partner/commercial-agreement gated — **no individual-developer access.** Don't re-chase. *(verified 2026-06-25)* |
| **iTunes Store** (buy, not Apple Music) | Very broad | 256k AAC, DRM-free | ❌ No clean server-side automation | Files are clean once purchased, but getting them off a phone to the server is manual. |

**The store decision is really an *automatability* decision, not a catalog one.**
On catalog alone Qobuz wins (it has the mainstream example). But the values-clean,
server-native, fully-automatic pipeline only exists *off-the-shelf* for **Bandcamp**.
So the recommended model is a **division of labor**, not a single primary:

- **Bandcamp = automated lane** (BandcampSync container → watch-folder; genuinely
  "buy on phone → appears in Jellyfin, untouched").
- **Qobuz = mainstream-catalog lane.** Two ways to do it (below): a *buildable*
  headless purchases-only fetcher (the clean automatic path), or — as an interim —
  the official GUI Downloader on a desktop synced to the server.
- **Never stream-rip.** `qobuz-dl`/streamrip pointed at *anything streamable* grabs
  rentals you don't own — exactly the grey-source path the "buy & own" thesis rejects.
  Only ever fetch items you've *purchased*.

## "Near-instant + on-the-go" — what's actually achievable

The honest latency story: the stores don't offer webhooks, so "instant" means
**frequent polling of your purchase history**, then fetch+ingest+scan. Realistic
end-to-end is **minutes**, not seconds — and only if the fetch step is automated.

**Per-lane reality** (this is what actually shapes the experience):
- **Bandcamp** — *genuinely* near-instant + on-the-go. BandcampSync polls on a
  timer, server-side, hands-off. Buy on phone → it appears.
- **Qobuz (purchases-API fetcher, if built)** — same: poll `getUserPurchases`,
  auto-fetch, minutes, hands-off. One mobile wrinkle (2026-07-15): the **iOS app
  can't purchase** (Apple IAP-cut avoidance, same as Kindle/Audible) — on-the-go
  buying happens in **mobile Safari at the qobuz.com store** (home-screen
  bookmark recommended). Purchases land on the account identically; the fetcher
  doesn't care which surface the buy came from.
- **Qobuz (interim GUI Downloader)** — **desktop-tethered, not on-the-go.** The
  official Downloader is Windows/macOS-only with no Linux/headless build, so it
  can't run on the apps VM. Flow degrades to "buy on phone → next time at the Mac,
  one click in the Downloader → Syncthing/rsync to the server watch-folder →
  appears in Jellyfin." Legit and robust, but needs you at a computer.

Plausible mechanics:
- **Poll the store's "my collection"/purchase API** every few minutes; on a new
  purchase, download the DRM-free files → drop into a beets import watch-folder.
- **Or a manual trigger** (a small web form / chat-bot command: "ingest this
  purchase URL") if polling is too fragile or ToS-risky.
- **beets auto-import** (watch-folder) tags via MusicBrainz, fetches art, files
  into `${STORAGE_PATH}/music`.
- **Jellyfin surfaces it** via real-time folder monitoring, or a scan triggered
  through Jellyfin's API right after the beets import (faster + deterministic).

## Tooling / prior art to evaluate

- **beets** — the ingest brain. MusicBrainz tagging, `fetchart`, `duplicates`,
  the `importfeeds`/hook plugins, and a watch-folder import pattern.
- **Lidarr** — the *experience* to emulate (monitor artist → auto-appears), but
  re-point its acquisition at legitimate sources or treat it as inspiration only.
- **Jellyfin** — real-time library monitoring vs scheduled scan vs API-triggered
  scan (`POST /Library/Refresh`). Decide which gives "near-instant" without
  hammering the library.
- **Store fetchers** — `qobuz-dl`, Bandcamp downloaders. **All unofficial and
  ToS-grey for automation** — flag clearly; only ever automate the admin's *own*
  purchases.

## Qobuz acquisition — build options (verified 2026-06-25)

The official Qobuz **Downloader is proprietary** (closed Electron app, Windows/macOS
only) and Qobuz has even **pulled its public API-documentation repo** (the
`Qobuz/api-documentation` GitHub repo and community mirrors now 404 — consistent with
the MassiveMusic B2B pivot). So there's no official source or docs to fork. But the
API *under* the Downloader is small, well-mapped, and proven in maintained
open-source clients — the whole "download my purchases" flow is **three calls**
(confirmed against [tidalf's Kodi plugin `raw.py`](https://github.com/tidalf/plugin.audio.qobuz/blob/master/resources/lib/qobuz/api/raw.py)):

```
1. user/login                  → auth token (x-user-auth-token + x-app-id)
2. purchase/getUserPurchases   → enumerate exactly what you OWN (incl. hires_purchased flag)
3. track/getFileUrl(intent=…)  → signed download URL for the FLAC
```

**The clean build = a "purchases-only" fetcher.** The ethical line between this and
a stream-ripper is *not* in the API — it's in **which items you feed to step 3**.
`qobuz-dl`/streamrip point `getFileUrl` at *anything streamable* (ripping rentals,
rejected). A fetcher that enumerates `getUserPurchases` first and *only* fetches
those items **can structurally only download things you paid for** — exactly what the
official Downloader does. Clean by construction, and it runs **headless on Linux /
in a container** (unlike the GUI Downloader), giving the fully-automatic Qobuz lane.
This is a small, coralstack-shaped artifact (cf. duckling / puddle on the photo side).

**Build from:**
- **[streamrip](https://github.com/nathom/streamrip)** (nathom) — actively maintained
  (v2.2.0, Mar 2026), Python 3.10+, CLI/headless, Linux. Already solves the two hard
  parts: **current auth** and the **signed `getFileUrl` download mechanics**
  (app_id/secret extraction + request signing). Reuse its plumbing; constrain input
  to `getUserPurchases`.
- **tidalf's `raw.py`** — minimal reference for the exact endpoint shapes + login flow.

**Risks (one is make-or-break):**
1. **Auth currency — RESOLVED IN DESIGN, probe pending (2026-07-15).** The
   password `user/login` flow is **confirmed broken** since ~2026-04: Qobuz now
   401s it (streamrip [#954](https://github.com/nathom/streamrip/issues/954),
   [#956](https://github.com/nathom/streamrip/issues/956), both open, no fix,
   no maintainer response; Qobuz officially moved to a token login,
   [#854](https://github.com/nathom/streamrip/issues/854)). The June note that
   streamrip's March release was "a good sign" was wrong — the breakage predates
   it being noticed. **The pivot:** streamrip's `use_auth_token` mode *also*
   routes through `user/login`, so don't depend on streamrip's login at all.
   Instead, extract `user_auth_token` from a logged-in **web-player session**
   (DevTools → Network → login response, or localStorage) and call the API
   directly with `X-App-Id` + `X-User-Auth-Token` headers — `user/login` exists
   only to mint that token, and the rest of the API doesn't need it. The
   three-call flow becomes two calls plus a rare manual token refresh. The
   fetcher still reuses streamrip's `QobuzSpoofer` for app_id/secret extraction
   (**verified working live 2026-07-15**: app_id + 3 secrets pulled from the
   web bundle).
2. **`intent`/entitlement** — confirm `getFileUrl` serves the *purchased* file (full
   owned quality), ideally without an active streaming sub.
3. **app_id/secret rotation** — embedded creds scraped from Qobuz's web bundle; Qobuz
   can rotate them. streamrip auto-extracts (the maintained way to stay current).
4. **ToS** — undocumented API + withdrawn public docs. Purchases-only is *far* more
   defensible than stream-ripping (retrieving what you bought, like the official app),
   but still unsanctioned automation. Honest grey, not green.

**Probe result (2026-07-15): GATES PASSED, with a quality ceiling — fetcher
greenlit AND built.** Verified live against a real purchase (Mumford & Sons —
*Prizefighter*): web-session token + spoofed app_id authenticated (`user/get`
200), `purchase/getUserPurchases` enumerated the album, and
`getFileUrl(intent=download)` served real FLAC files with no streaming
subscription. The token-auth pivot works end-to-end and the whole back half now
runs (see [below](#whats-built-2026-07-15)).

**⚠️ Quality ceiling — download tops out at 24-bit/96 kHz, NOT the 24/192 you
buy.** The initial probe's step 4 was too lenient (it checked for *metadata*,
not an actual download URL) and falsely reported 24/192. Corrected: with a
web-session token + the **web-player app_id**, `getFileUrl(intent=download)`
for **format 27 (24-bit/>96 kHz)** is refused —
`TrackRestrictedByPurchaseCredentials` — *even for a hi-res purchase*. Only the
**official Downloader's app credentials** unlock the 192 kHz tier. **Format 7
(24-bit/96 kHz) downloads cleanly**, so the fetcher walks a ladder 27 → 7 → 6
and lands on genuine hi-res 24/96. This is far beyond CD and excellent for
listening, but it is *not* byte-identical to the 24/192 master. If bit-perfect
archival of the top tier ever matters, that's the one job the desktop GUI
Downloader still does that this lane can't — an argument for keeping the
Downloader-on-a-desktop fallback documented, not deleted. (Ripping the app_id
out of the *desktop* Downloader to get 192 headless is possible in principle
but a real reverse-engineering project and more ToS-aggressive; not pursued.)

**Other notes:** the admin's Qobuz account is on the gmail identity; the iOS
app can't purchase (buy via mobile Safari — see the latency section); **token
lifetime is the one remaining unknown** — the probe token survived hours on day
one; re-run the probe with the same token after a week to size the manual
re-auth burden before deciding how loudly the fetcher should alarm on 401.

### What's built (2026-07-15)

The **deterministic back half is done and proven end-to-end** (imported
*Prizefighter* start-to-finish in a test container):

- **`services/music/` service** — a containerized beets watch-folder
  (`coralstack/music-ingest:beets-2.12.0`, custom image like `caddy/` and
  `backup/`). `ingest.sh` polls `${STORAGE_PATH}/music-staging`, waits for the
  drop to go **quiescent** (no file touched for `QUIESCENCE_SECONDS`, so a
  half-copied album is never imported), runs a `--quiet` beets import that
  **moves** (atomic, same filesystem) accepted files into
  `${STORAGE_PATH}/music`, sweeps anything beets rejects to
  `music-staging/.review`, and fires Jellyfin's `POST /Library/Refresh`. beets
  config: MusicBrainz tagging with `quiet_fallback: asis` (store files arrive
  well-tagged — verified: artist/album/title/track/date all survive, cover art
  embedded), `fetchart` + `embedart`. Wired into root `docker-compose.yml`.
- **`services/music/qobuz-fetch.py`** — the purchases-only fetcher (v0,
  one-shot). Enumerates `getUserPurchases`, downloads each owned track at the
  best obtainable quality (ladder above) into staging, skips existing files
  (idempotent re-runs), only ever exposes complete files (`.part` → rename).
  Run manually with `QOBUZ_TOKEN`; the containerized poll loop is the next build.
- **Jellyfin compose + `.env.example`** — the stale "beets on the host"
  comments corrected to point at the music-ingest container as the sole writer.

**Surfacing: Jellyfin real-time monitoring — no API key needed (verified
2026-07-15).** The Music library on `coralstack-apps` has
`EnableRealtimeMonitor=true`, and `${STORAGE_PATH}` is a **local ext4** volume
(`/dev/sdb`), so Jellyfin's inotify watcher reliably catches beets' atomic
renames into `/media/music` and rescans on its own. This is the primary (and
sufficient) surfacing mechanism — new albums appear with **no `JELLYFIN_API_KEY`
and no `/Library/Refresh` call**.

The container's `/Library/Refresh` POST is therefore an **optional accelerator**,
not a requirement: with no key set it logs a harmless skip (current state); set
`JELLYFIN_API_KEY` in `services/music/.env` only if you later want an immediate
deterministic scan on top of real-time monitoring (e.g. if monitoring ever lags
under load, or if the library moves to storage where inotify is unreliable —
NFS/SMB). There is **no API key to provision** for the pipeline to work.
(Jellyfin runs on `coralstack-apps`, 10.0.0.10; the container reaches it in-stack
at `http://jellyfin:8096`.)

**The probe:**
[services/music/qobuz-probe.py](../services/music/qobuz-probe.py) checks the
make-or-break questions (token validity, `getUserPurchases`, and — with the
2026-07-15 fix — `getFileUrl(intent=download)` returning an actual **download
URL** at the best obtainable tier, reporting honestly when the 24/192 tier is
refused) without touching the broken `user/login`. It doubles as the
**token-lifetime check**: re-run it with the same token weekly. Run with a
token extracted from a logged-in play.qobuz.com session:

```
QOBUZ_TOKEN=<token> uv run services/music/qobuz-probe.py
```

Requires at least one purchase on the account to complete the entitlement step.

## Architecture — as built + what remains

`services/music/` (the [What's built](#whats-built-2026-07-15) section has the detail):
- **beets ingest** ✅ — containerized watch-folder, staging → `${STORAGE_PATH}/music`.
- **Jellyfin surfacing** ✅ — real-time monitoring (no API key; see above).
- **Acquisition — Qobuz** ✅ **fully automatic**: `qobuz-poll` container polls
  `getUserPurchases` every `QOBUZ_POLL_INTERVAL` (default 15 min) and downloads
  new purchases into staging hands-off, keyed off a persistent **watermark** of
  fetched track IDs (so re-polls never re-download even after ingest drains
  staging). `qobuz-fetch.py` still works as a manual one-shot.
- **Acquisition — Bandcamp** — BandcampSync container, off-the-shelf, not yet added.

The whole Qobuz lane is now hands-off end to end. The remaining store work is
adding the Bandcamp lane when desired.

## Open questions for the next session (decide *with* the admin)

1. **Store strategy — RESOLVED (2026-07-15):** **Bandcamp (automated lane) +
   Qobuz (mainstream lane)**; 7digital ruled out. The Qobuz *how* is decided too:
   the headless **purchases-only fetcher**, greenlit by the passed probe
   (`services/music/qobuz-probe.py` — all 4 gates, real purchase, full hi-res
   file). The GUI-Downloader interim is now just the fallback if token
   maintenance proves too annoying in practice.
2. **Acquisition trigger:** automated polling vs manual "ingest this" trigger?
   (ToS + reliability tradeoff.) Note: Bandcamp is already polling-on-a-timer via
   BandcampSync; this question is really about the Qobuz poll-loop wrapper.
3. **~~beets: container or host?~~** RESOLVED — containerized (`services/music/`).
4. **Backup stance:** if music is now *purchased & owned*, should it stop being
   excluded from offsite backup? (See [BACKUPS.md](BACKUPS.md).) Sharper now
   that the download tier is 24/96, not the 24/192 you paid for: the local files
   are *not* a perfect re-download of the purchase, which strengthens the case
   for backing them up rather than treating them as trivially re-acquirable.
5. **Quality ceiling:** is 24/96 acceptable as the standing quality, or is
   bit-perfect 24/192 worth keeping the desktop Downloader around for
   occasional archival buys? (See the ceiling note above.)
6. **Mobile UX:** which Jellyfin music client (Finamp, Symfonium, official)?
   Confirm the "playable on-the-go" half independent of acquisition.
7. **Migration vs acquisition:** the existing-library import does *not* belong
   here — keep this doc focused on ongoing acquisition. It needs a member-side
   tool of its own (home TBD; it was slated for coralstack-migrator before that
   repo was archived).

## Next step

The Qobuz lane is built, deployed, and hands-off (`qobuz-poll` on coralstack-apps).
What's left is operational + optional:

1. **Token lifetime** — the one open unknown for unattended running. `qobuz-poll`
   reads `QOBUZ_TOKEN` from `services/music/.env` at container start; on a 401 it
   logs a re-auth warning and keeps retrying. Re-extract a fresh token from a
   play.qobuz.com session when it expires and reload with
   `docker compose up -d qobuz-poll`. Observe how often that's needed; if it's
   frequent, revisit the headless-login refresh sidecar (the account has a
   Qobuz-native password, so that path is viable).
2. **Bandcamp lane** — add BandcampSync when you start buying there.
3. **Backup stance** — revisit excluding music from offsite backup now that it's
   purchased & owned and only obtainable at 24/96 (not a perfect re-download).
