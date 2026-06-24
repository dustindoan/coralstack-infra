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

| Store | Catalog | Format | Automatable? | Notes |
|---|---|---|---|---|
| **Bandcamp** | Indie-heavy; **patchy for major labels** | MP3/FLAC, DRM-free | Purchases sit in your "collection"; unofficial downloaders exist | Most artist-direct / co-op-aligned. **The Mumford & Sons example likely *isn't* here** (major label). |
| **Qobuz** | Broad incl. major labels (Mumford & Sons ✓); Hi-Res | FLAC up to hi-res, DRM-free purchase | `qobuz-dl` (unofficial) can fetch purchased/streamable content | Best fit for the stated mainstream example. ToS grey area for automation. |
| **7digital** | Broad, major labels | MP3/FLAC, DRM-free | Has an API (historically partner-gated) | Worth checking current API access. |
| **iTunes Store** (buy, not Apple Music) | Very broad | 256k AAC, DRM-free | No clean server-side automation | Files are clean once purchased, but getting them off a phone to the server is manual. |

**Reality check on the example:** a brand-new major-label release means
**Qobuz / 7digital / iTunes**, not Bandcamp. So the realistic primary is
probably Qobuz (best catalog+quality+DRM-free ownership), with Bandcamp as the
artist-direct option when available.

## "Near-instant + on-the-go" — what's actually achievable

The honest latency story: the stores don't offer webhooks, so "instant" means
**frequent polling of your purchase history**, then fetch+ingest+scan. Realistic
end-to-end is **minutes**, not seconds — and only if the fetch step is automated.

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

1. **Primary store?** Qobuz (best for the mainstream example) vs Bandcamp
   (values-aligned) vs both. Drives everything downstream.
2. **Acquisition trigger:** automated polling vs manual "ingest this" trigger?
   (ToS + reliability tradeoff.)
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
