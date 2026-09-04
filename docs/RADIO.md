# CoralStack Radio — a licensed community station

> **Status:** 💭 exploration / hand-off doc (2026-08-30). No code yet. This
> frames why a station is the *only* legitimate way members hear each other's
> music, what it costs, what constrains it, and the phased build that defers
> every dollar of licensing until the product hypothesis is proven. It is
> adjacent to [MUSIC_ACQUISITION.md](MUSIC_ACQUISITION.md) — that doc covers
> *buy → own → play* for one person; this one covers the one thing that
> pipeline structurally cannot do.

## The north star

> "Hear something on the co-op's station, tap once, own it forever — and have
> that purchase feed back into what the station plays next."

## Why this doc exists

The obvious feature — one shared music library the whole co-op browses and
plays from — **is not available to us**, and the reasoning matters enough to
write down so it doesn't get re-litigated:

- A Qobuz/Bandcamp purchase is a **personal-use licence granted to the
  purchaser**. Serving those files to other households is distribution.
- It is *specifically* damaging here because
  [MUSIC_ACQUISITION.md](MUSIC_ACQUISITION.md#the-central-tension-buy--own-vs-auto-grab)
  rejects Lidarr-style auto-grab on ethics. One member buys once and N
  households stream it is **functionally the same transfer** with a legitimate
  purchase laundering the acquisition step. The "artist-supporting" claim does
  not survive it.
- The clever workarounds are the most-litigated idea in this area of law and
  they lose. *ABC v. Aereo* (US 2013) killed architecture-as-defence;
  **_Rogers v. SOCAN_, 2012 SCC 35 — the controlling Canadian case — held that
  point-to-point, user-initiated, one-at-a-time streams ARE communications to
  the public**; *UMG v. MP3.com* (2000) killed the ownership-gated variant
  specifically; *Capitol v. ReDigi* (2018) confirmed digital transfer makes a
  new copy, so first sale doesn't reach files. A "member requests, server
  auto-accepts" design also **inverts** the liability rather than removing it:
  if the member is the actor, the member has no licence at all, and we built
  and operate the machine — squarely at Canada's s. 27(2.3) enabling provision.

**Radio is the escape hatch, and not merely as a consolation prize.** The
pooling happens at the *programming* layer, not the *file* layer: the station
reads files server-side and emits one mixed stream. Per-member Jellyfin
libraries stay sealed. The only thing crossing the boundary is audio a tariff
covers.

> **⚠️ Doc debt this creates.** Two live claims currently describe the thing we
> can't do and should be corrected independently of this project:
> [MEMBER_ONBOARDING.md](MEMBER_ONBOARDING.md) ("the **shared** music library")
> and [SITE_COPY.md](SITE_COPY.md) ("**your community's** media library... your
> music collection lives here too"). The movies/TV half of those sentences is a
> different, admin-plane posture; music is the lane we deliberately keep clean,
> and the copy currently blurs them.

## Why radio is the right format (not just the permitted one)

**The inversion:** on-demand, library size is a liability — 2,000 albums beside
Apple's 100M is a rounding error, and every session begins with the member
noticing what isn't there. On radio, 2,000 albums is *abundant*: a station runs
for months without repeating, and the listener never encounters the boundary
because they were never reaching for a specific track.

Radio is the one format where an owned collection **outperforms** the infinite
catalogue, because every track on it was bought by someone with taste, on
purpose. The curation already happened at the cash register.

It also recovers, legitimately, the feature the shared shelf was really for:
*"That was Prizefighter — from Alice's shelf, bought Tuesday."*

## The flywheel

```
  radio  →  "what IS this?"  →  Crate  →  buy  →  own  →  ingest  →  radio
 discovery      the hook       wantlist  Qobuz  personal  beets    (back in
                                        /Bandcamp  library         rotation)
```

Every arrow is artist-positive, and **Spotify structurally cannot build this
loop** — there is no purchase for discovery to convert into. The single most
important UI element in the concept is therefore one button on the radio
player: **"I want this."**

("Crate" is the working name for the acquisition surface in the Jellify UI —
search spanning owned + buyable, buy deep-link, and an arriving tray. Specced
separately; not yet written up.)

## What it plays

| Channel | Content | Notes |
| --- | --- | --- |
| **New Arrivals** | What members bought this week | The flagship. Makes co-op purchasing audible — the licensed version of the "co-op added this today" feed |
| **The Shelf** | Everything, weighted to unplayed deep cuts | Broad by design → satisfies the complement effortlessly (see below) |
| **Dayparts** | Morning / dinner / late night | Where local-LLM programming earns its keep |
| **Shows** | A member programs a set, airs weekly | Non-interactivity constrains the **listener**, not the **programmer** — a DJ picking a sequence is just radio. Can't pre-publish the playlist |
| ~~Per-member stations~~ | ~~"Alice's Shelf"~~ | ❌ **Legally the worst idea in the list** — see complement, below |

### The AI DJ

Ollama already runs in the stack (Mac mini, per
[ROADMAP.md](ROADMAP.md) Phase 1). A local model writes between-track patter
from provenance beets already stores; a small local TTS (Piper, Kokoro — CPU,
tiny) voices it. Patter is the difference between a station and a shuffle, and
it is exactly on-brand: private AI, owned hardware, doing something delightful.

Note: Jellify already carries an unused `openai` dependency in `package.json`
with zero source references — an OpenAI-compatible base URL pointed at Ollama
is close to free.

## Legal basis

**Non-interactive webcasting is available under statutory tariff.** You pay a
set rate; no negotiation with labels is required. Canada splits the rights, so
there are **two collectives**:

| Collective | Covers | Tariff |
| --- | --- | --- |
| **Re:Sound** | Performers + makers of the sound recording | Webcasting / online audio |
| **SOCAN** | Composers + publishers | Online audio services |

**CRTC: not applicable.** Internet-only audio needed no CRTC licence under the
Digital Media Exemption Order; the Online Streaming Act (C-11) brought online
undertakings in-scope but set registration thresholds at $10M annual Canadian
revenue. A co-op is nowhere near. Don't re-chase this.

### What "non-interactive" requires

The **sound recording performance complement** caps repetition in a rolling
window. The US §114 version is the well-documented shape — no more than 4
tracks by one artist in 3 hours (3 consecutively), no more than 3 from one
album (2 consecutively), no pre-published playlists. **Canada's conditions
differ in detail; confirm the actual ones.**

**Limited skips are compatible with non-interactive status** (this is how
Pandora operates: capped skips, thumbs up/down, no rewind, no on-demand). So
some interactivity is available without falling into the pricier
semi-interactive tier.

### ⚠️ What the tariff does NOT cover

**The tariff licenses the copyright. It says nothing about your contract with
the store.** Qobuz's personal-use terms may restrict what you do with a
downloaded file regardless of whether the performance is licensed. Copyright
permission and contractual permission are **separate layers and you need
both** — and the tariff *feels* like it settles everything, which is exactly
why this gets missed.

Practical consequence: **ripped CDs and Bandcamp purchases are likely cleaner
source material for the station than Qobuz downloads.** Confirm before station
programming is built on the Qobuz lane specifically. Breach of ToS is also the
one failure mode that costs you the whole library (account termination →
no re-download).

## Costs

> All figures directional — Copyright Board tariffs are re-set periodically.
> The structural analysis holds; the digits need a phone call. **Nothing below
> has been confirmed with either collective as of 2026-08-30.**

### The minimums are the bill

Historically, small non-commercial non-interactive webcasting carried annual
minimums in the **low hundreds of dollars** at each collective. Budget **a few
hundred dollars a year, total**. This space is gated by paperwork, not by five
figures and lawyers.

### The variable rate never binds at our scale

Per-play-per-listener rates run in fractions of a cent. At co-op scale:

```
  5 members x 2 h/day          =  3,650 listener-hours/year
  x ~15 tracks/hour            = ~55,000 plays-per-listener/year
  x ~$0.0001 per play/listener =  ~$5.50/year
```

**The cost is a floor, not a meter.** Consequence worth internalising: once the
minimum is paid, **more listening is free**. A member listening 8 h/day adds
nothing. We would need to be ~2 orders of magnitude larger before usage-based
fees mattered — so there is no reason to be shy about promoting the station
internally.

### Everything else

| Cost | Estimate |
| --- | --- |
| Compute | ~1 core per *actively encoded* stream; ~0 if Liquidsoap idles empty channels. Budget deliberately — the box already does Jellyfin transcodes |
| Bandwidth | 128 kbps ≈ 57 MB/listener-hour → ~200 GB/year at the scale above. Trivial on fibre |
| Storage | Negligible (no new media; logs only) |
| **Your time** | **The actual cost, not close.** Reporting pipeline, Liquidsoap programming, Jellify live-player work, annual filing ritual |
| Professional advice | ~1 hour of a lawyer or music-licensing consultant to read both tariffs correctly, once. Worth spending |

## What constrains the number of stations

Ranked by how hard they actually bite. The answer is *not* cost.

**1. The performance complement — and it gets worse the more stations you
run.** A single broad station satisfies the complement effortlessly; wide
programming spreads artists out on its own. **Narrow themed stations violate it
structurally** — a per-member channel, a single-artist deep dive, or a tight
genre station clusters artists and albums *by design*. The narrower and more
appealing the concept, the harder it is to keep legal.

Deeper version of the same problem: **a station narrow enough becomes
functionally interactive.** If "Alice's Shelf" holds 40 albums, a listener who
wants a specific track just tunes in and waits. That is substitution for a
sale — precisely what non-interactivity exists to prevent — and it drifts us
out of the tariff we're paying for.

> **So the constraint on many stations is that the stations people would most
> want are the ones we can least legally build.** This is the finding.

**2. Per-channel minimum fees — the single highest-leverage unknown.** In the
US, SoundExchange minimums are explicitly **per channel or station per year**,
which is the mechanism that brakes multi-channel services. Whether Re:Sound and
SOCAN treat minimums per-*service* or per-*channel* determines the entire shape
of the product:

- **Per-service** → many stations are ~free. A person can only listen to one at
  a time, so variable cost is bounded by total ears, not channel count.
  Splitting one station into ten redistributes listening; it doesn't create it.
- **Per-channel** → each station carries a floor cost. Build two or three, not
  twenty.

**3. Reporting scales per channel.** Play logs per stream — track, artist,
album, ideally ISRC, listener counts. This is the burden that kills most
hobbyist stations. **We are unusually well-positioned:** beets already tags via
MusicBrainz, so we hold identifiers most people don't. Still a real build.

**4. Audience and curation quality.** A five-person co-op cannot sustain twenty
stations. Attention is the scarcest input; ten mediocre channels are strictly
worse than one great one. Liquidsoap makes *generating* stations trivial —
making them worth tuning into is the same human work it has always been.

**5. Qobuz ToS** — see the ⚠️ above. Applies per-station only in the sense that
it may constrain *source material* across all of them.

## The free lane — unlimited stations, no tariff

A whole category carries **no tariff, no reporting, and no station-count
limit**, publishable to the open internet:

- **Creative Commons / public domain** — Free Music Archive, netlabels, the
  large CC-BY catalogue.
- **Artist-permitted material** — many Bandcamp artists explicitly allow it.
- **Local artists, by direct permission.** The one worth chasing. Campbell
  River and the north island have musicians who would sign a one-paragraph
  permission to be played on a community station.

That last one matters strategically: **the free path and the on-brand path are
the same path.** A co-op that *platforms* local players is a far better story
than a co-op that streams its own records — and it is the most defensible thing
we could put on the front page of coralstack.org.

## Architecture

**Liquidsoap → Icecast**, containerized as `services/radio/` — the mature,
boring, correct stack. Liquidsoap is a real audio-programming language
(crossfades, scheduling, jingles, fallbacks, per-channel logic); Icecast serves
it. Fits the compose-per-service convention.

Two outputs:

- **HLS → Jellify/iOS.** Rides on infrastructure we just fought for and
  understand: the app's `fix/ios-hls-transcode-profile` work plus the
  nitro-player seam waiver. AVPlayer handles live HLS natively.
- **Icecast MP3/Ogg → everything else.** Browsers, Sonos, a laptop, anything
  that takes a URL.

**Encode on demand.** Liquidsoap can idle when nobody is listening. Don't burn
a core around the clock for an empty room on a box that already carries the
whole stack.

**Read access:** the radio service reads member library trees directly from
disk as a server-side process. It is *not* a Jellyfin user and grants no member
access to another member's files.

## What Jellify needs

Non-trivial, but in code we now know well:

- Live-stream player mode — no duration, no scrubbing, no seek bar. The Player
  screen currently assumes a track with bounds.
- "Now playing" from stream metadata (ICY, or ID3-in-HLS timed metadata) rather
  than from the queue.
- A Radio tab / channel picker.
- **The "I want this" button** and its wantlist plumbing — the conversion point
  of the whole flywheel.
- CarPlay + lockscreen treatment for a live source.

## Phasing

**The sequencing principle: don't buy the licence until you know you'd listen.**
Most radio projects die of "built it, never tuned in" — and that failure costs
nothing to discover at Phase 0.

| Phase | Scope | Licence | Gate to advance |
| --- | --- | --- | --- |
| **0** | **Household only.** Liquidsoap + HLS + a Radio tab in Jellify | ❌ none needed — a single-household private stream is not a communication to the public | You actually listen, unprompted, for a few weeks |
| **1** | AI DJ + New Arrivals channel. Still household-only | ❌ none | The station feels alive rather than like a playlist with extra steps |
| **2** | Open to the co-op | ✅ **required** — Re:Sound + SOCAN | A second household commits (this is already the [ROADMAP](ROADMAP.md) Phase 2 trigger) |

Phase 2's licensing cost arrives at exactly the moment a second household makes
the station both legally necessary and musically viable — a small library makes
the complement *binding*, so the station genuinely gets better as the co-op
grows. Right incentive, but a real gate.

The **free lane** (CC / local artists) can run at any phase, in parallel, with
no licence at all.

## Open questions for the next session (decide *with* the admin)

1. **Per-channel or per-service minimums?** (Re:Sound and SOCAN, separately.)
   **Blocking** — determines whether the product is 2 stations or 20.
2. **Current non-commercial non-interactive rates**, both collectives.
3. **Required reporting format**, both collectives — shapes the logging build.
4. **Canada's actual complement conditions** (the §114 numbers above are the US
   illustration, not our rule).
5. **Does Qobuz's ToS permit using downloaded files as station source
   material?** If not, is the station built on ripped CDs + Bandcamp only?
6. **Territoriality** — tariffs are national. A member listening from outside
   Canada is murky. Geo-scope, or accept the ambiguity?
7. **Is Phase 0 worth building at all** if the answer to #1 is bad? (Probably
   yes — the free lane survives either way.)

## Next step

**One call to Re:Sound and one to SOCAN**, asking questions 1–4 above. Roughly
forty minutes, and it settles the architecture before a line of Liquidsoap is
written.

Independently and in parallel: **Phase 0 needs no permission from anyone.**
A household-only stream is buildable today and is the cheapest possible test of
whether this is a product or a daydream.
