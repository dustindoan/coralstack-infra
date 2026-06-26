# Music acquisition & ingest — purchase → library → Jellyfin

> **Status:** 💭 exploration / hand-off doc. No code yet. This frames the
> problem, the options, and the decisions a future session needs to make *with
> the admin* before building. It is the substance behind
> [LAUNCH_BLOCKERS](LAUNCH_BLOCKERS.md) gate #2 (music) and the planned
> `media` module in [coralstack-migrator](https://github.com/dustindoan/coralstack-migrator).

## The north star

> "Buy the new Mumford & Sons album on-the-go, and have it appear in my
> collection and be playable through a Jellyfin music app automatically and
> near-instantaneously."

Two distinct things hide in gate #2:
1. **Migration** — get the admin's *existing* library onto the stack (one-time;
   belongs in coralstack-migrator's `media` module, mirrors the photo path).
2. **Acquisition** — an ongoing *buy → owned → playable* pipeline. **This doc is
   mostly about #2**, which is the more interesting (and more product-shaped)
   problem and the one the admin is excited about.

## Current state (verified 2026-06-24)

- Jellyfin mounts the library **read-only**: `${STORAGE_PATH}/music:/media/music:ro`
  (see [services/jellyfin/docker-compose.yml](../services/jellyfin/docker-compose.yml)).
- **beets is referenced but not implemented.** `.env.example` and the Jellyfin
  compose comment say the library is "managed by beets on the host" — but there
  is **no beets service in the repo** and no host runbook for it. Treat beets as
  *intended, not built*. A future session should decide whether beets runs in a
  container (reproducible, fits the stack) or on the host (as the comments imply).
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
| **Qobuz** | Broad incl. major labels (Mumford & Sons ✓); Hi-Res | FLAC up to hi-res, DRM-free purchase | ⚠️ **Buildable, not off-the-shelf** — see [Qobuz acquisition](#qobuz-acquisition--build-options-verified-2026-06-25). The purchases-API path is clean *by construction*; the GUI Downloader is desktop-only; `qobuz-dl`/streamrip default to **stream-ripping (rejected)** | Best catalog for the mainstream example. The clean automated lane requires building a small purchases-only fetcher; auth currency is the gating risk. |
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
  auto-fetch, minutes, hands-off.
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
This is a small, coralstack-shaped artifact (cf. the Ente upload sidecar / migrator).

**Build from:**
- **[streamrip](https://github.com/nathom/streamrip)** (nathom) — actively maintained
  (v2.2.0, Mar 2026), Python 3.10+, CLI/headless, Linux. Already solves the two hard
  parts: **current auth** and the **signed `getFileUrl` download mechanics**
  (app_id/secret extraction + request signing). Reuse its plumbing; constrain input
  to `getUserPurchases`.
- **tidalf's `raw.py`** — minimal reference for the exact endpoint shapes + login flow.

**Risks (one is make-or-break):**
1. **Auth currency — THE gating unknown.** `user/login → x-user-auth-token` is the
   flow Qobuz's OAuth migration disrupted (it's what broke `qobuz-dl`). streamrip's
   March 2026 release is a *good* sign it's been kept working, but **verify first.**
2. **`intent`/entitlement** — confirm `getFileUrl` serves the *purchased* file (full
   owned quality), ideally without an active streaming sub.
3. **app_id/secret rotation** — embedded creds scraped from Qobuz's web bundle; Qobuz
   can rotate them. streamrip auto-extracts (the maintained way to stay current).
4. **ToS** — undocumented API + withdrawn public docs. Purchases-only is *far* more
   defensible than stream-ripping (retrieving what you bought, like the official app),
   but still unsanctioned automation. Honest grey, not green.

**Gating first step (one afternoon, before any code):** install streamrip and confirm
it still authenticates to a live Qobuz account today. If yes → the purchases-only
fetcher is a weekend project and the automatic Qobuz lane is real. If no → fall back
to the interim GUI-Downloader-on-a-desktop + Syncthing pattern, and Qobuz stays
desktop-tethered until auth is solved.

## Architecture sketch (for the building session)

A new `services/music/` (or extend coralstack-migrator's `media` module):
- **Acquisition watcher** — polls the chosen store's purchase history (creds in
  gitignored `services/music/.env`), downloads DRM-free files to a staging dir.
- **beets ingest** — containerized beets imports staging → `${STORAGE_PATH}/music`.
  (Reconcile with the "beets on host" note: containerizing is more reproducible.)
- **Jellyfin scan trigger** — call Jellyfin's refresh API after import.

The deterministic back half (beets watch-folder + Jellyfin scan) can be built and
proven **first**, independent of any store. The store-specific front half
(purchase → fetch) is staged on top once a store is chosen.

## Open questions for the next session (decide *with* the admin)

1. **Store strategy — largely resolved by the 2026-06-25 dig:** it's
   **Bandcamp (automated lane) + Qobuz (mainstream lane)**, not a single primary;
   7digital is ruled out. The remaining open call is *how* Qobuz runs: build the
   headless **purchases-only fetcher** (clean + automatic) vs the interim
   **GUI-Downloader-on-a-desktop + Syncthing** (desktop-tethered). **Gated entirely
   on the streamrip auth probe** — run that first (see [Qobuz acquisition](#qobuz-acquisition--build-options-verified-2026-06-25)).
2. **Acquisition trigger:** automated polling vs manual "ingest this" trigger?
   (ToS + reliability tradeoff.) Note: Bandcamp is already polling-on-a-timer via
   BandcampSync; this question is really about the Qobuz lane.
3. **beets: container or host?** (Repo convention says containerize.)
4. **Backup stance:** if music is now *purchased & owned*, should it stop being
   excluded from offsite backup? (See [BACKUPS.md](BACKUPS.md).)
5. **Mobile UX:** which Jellyfin music client (Finamp, Symfonium, official)?
   Confirm the "playable on-the-go" half independent of acquisition.
6. **Migration vs acquisition:** does the existing-library import belong here or
   in coralstack-migrator's `media` module? (Probably the migrator; keep this
   doc focused on ongoing acquisition.)

## Recommended first step

Build and prove the **deterministic back half** — a containerized beets
watch-folder that ingests into `${STORAGE_PATH}/music` and triggers a Jellyfin
scan — using a single manually-dropped album. That de-risks stages 3–4 and gives
a working spine. *Then* pick a store and build the purchase→fetch front half.
