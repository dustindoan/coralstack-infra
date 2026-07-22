# coralstack.org — site copy, draft v1 (2026-07-15)

Draft copy for the public landing page (launch gate #5). Decisions baked in:

- **Primary reader: the member/consumer** — the person whose photos and passwords
  move. Host-admins are the secondary reader, addressed near the end.
- **Model: free OSS + "contact me."** No pricing page, no billing signals.
  Trials are invite-only via direct contact.
- **Live TV / Dispatcharr: omitted** from the public story entirely.
- Early-stage honesty per [LAUNCH_BLOCKERS.md](LAUNCH_BLOCKERS.md) — disclosures
  are content, not fine print.

Structure notes are in *[brackets]*; everything else is copy.

---

## Hero

*[Full-viewport. One claim, one subtitle, three buttons. The 60-second test is
won or lost here.]*

# Your photos, on hardware your community owns.

The cloud, brought home.

CoralStack is an open-source template for replacing iCloud Photos, your password
manager, your music library, and your AI chat — with services running on a small
computer in someone's home. Someone you know. Built for households, friend
groups, and co-ops.

*[Buttons:]* **What you get** · **Interested? Talk to us** · **GitHub**

## Something worth owning

*[Short section, 3 paragraphs. This is the "why now," told as a future to build
toward, not a threat to flee.]*

Imagine your photos, your passwords, and your everyday AI living on a small
computer you can point to — in a home, in your community, on hardware that
belongs to people you know. Not rented. Not mined. Just yours.

That's more possible now than it's been in years. The tools got good:
open-source software, end-to-end encryption, and hardware cheap enough to sit on
a shelf. What used to take a data center now fits in a room.

It's also more worth doing. As photos, passwords, and daily reasoning move deeper
into a handful of platforms — Google retired its Photos Library API in 2025,
cloud infrastructure keeps consolidating (three companies now hold
[85% of Canada's market](https://www.cbc.ca/news/business/cloud-computing-competition-9.7219996)),
AI is following the same path — the gap between the people who **own** the
infrastructure and the people who merely **rent** it only widens.
It's the same story [Gary Stevenson](https://www.youtube.com/watch?v=iD2sPL7k98c)
tells about wealth: ownership compounds, and renting quietly costs you more every
year. CoralStack is a small move to the ownership side of that line — boring,
durable, and genuinely yours. Not a different landlord.

## What you get

*[Card grid, member perspective. Each card: name, one-liner, "powered by X"
in small type — lead with the outcome, not the project name.]*

- **Photos** — Your camera roll backs up automatically, end-to-end encrypted.
  Not even the server can see your pictures. Albums, sharing, search — on all
  your devices. *(powered by Ente)*
- **Passwords** — A full password manager with apps for every phone and browser,
  autofill included. Your vault is encrypted with a passphrase only you know.
  *(powered by Vaultwarden, Bitwarden-compatible)*
- **Movies, TV & music** — Your community's media library, streaming to your
  phone, laptop, and TV. Your music collection lives here too — owned, not
  rented. *(powered by Jellyfin)*
- **Private AI chat** — A capable AI assistant running on community hardware
  with open models. Conversations never leave the building. *(powered by
  Open WebUI)*
- **One login** — A passkey: your fingerprint or face, no passwords to remember,
  nothing to phish. Every service above accepts it. *(powered by Pocket ID)*
- **A straight answer when something breaks** — A public status page shows
  exactly what's up and what's down. No "we're aware of an issue."

## What it replaces — and what it doesn't

*[Two-column honesty table. This section builds more trust than the features do.]*

| You use today | CoralStack today |
| --- | --- |
| iCloud / Google Photos | ✅ Ente — e2ee photo backup, sharing, search |
| 1Password / iCloud Keychain | ✅ Vaultwarden — full Bitwarden apps |
| Apple Music (your library) | ✅ Jellyfin — your owned collection, streamed |
| ChatGPT-style assistant | ✅ Open WebUI + open models |
| Spotify-style catalogs | ❌ Plays what you own. Buy from Bandcamp/Qobuz, rip CDs — we document how |
| iCloud Contacts & Calendar | ❌ Not yet. Keep iCloud for these, or self-host Baikal/Radicale alongside |
| iCloud Drive / file sync | ❌ Not yet. Syncthing or Seafile work alongside if you need it |

No lock-in in either direction: photos, passwords, and media all export in
standard formats. Leaving CoralStack is documented the same as joining.

## How it works

*[Four steps, one sentence each, optional simple diagram.]*

1. One small, dedicated computer lives at a member's home.
2. Your community gets its own domain; every service is a subdomain of it.
3. You sign in to everything with one passkey.
4. Encrypted backups go off-site nightly — and we've tested restoring them.

Everything in the stack is open source, and the whole configuration is public:
*[link: GitHub repo]*.

## Honest expectations

*[Do not soften this section. The audience self-selects on it.]*

CoralStack is **early-stage**. One community runs it today, operated by the
maintainer. If that excites rather than worries you, you're the audience.

- **Joining is high-touch.** A real person (your host-admin) sets you up — the
  guided path takes about 30 minutes per member, and someone is there for it.
- **It's one machine.** Maintenance windows happen. The status page will always
  tell you the truth about what's down.
- **Some things aren't replaced yet** — contacts, calendar, and file sync are
  the honest gaps (see the table above).
- **We diverge from defaults deliberately.** Where standard home-server defaults
  assume "hobby project," we've hardened for "my community depends on this" —
  and we document every divergence.

## Run one for your people

*[Secondary audience section — the host-admin. Compact.]*

Self-hosting already works — for the technical. You can probably solve photos,
passwords, and AI for yourself; most people can't, and that's the whole gap: for
two decades this movement has freed the technophiles and left everyone else on the
rented internet. Your parents, your neighbours, the co-op down the road don't need
to learn Linux — they need to know someone who has. That's you.

CoralStack is built so one person's weekend covers a whole household, not just
themselves. Everything the maintainer's community runs is in one public repo:
infrastructure as code, setup script, runbooks, backup and recovery, onboarding
guides for you and your members.

You'd need: a dedicated mini-PC (never your daily-driver machine), Ubuntu Server,
a domain, a weekend to set up, and the temperament to be your community's
sysadmin. AGPL-3.0 — free, forever, copyleft.

**Talk to us before you deploy.** Not because you must — because the install has
so far been run by one person, and you'd be among the first to change that. Be
the person who hosts for the people who can't host for themselves. We want to
hear where it breaks.

*[Buttons:]* **Read the quickstart** · **Contact the maintainer**

## FAQ

*[Collapsed accordion. Five entries.]*

**Why not just Nextcloud?**
Nextcloud is one app trying to be everything. CoralStack composes the best
dedicated open-source app for each job — Ente for photos, Vaultwarden for
passwords, Jellyfin for media — behind one login. Different trade-off, more
moving parts, better apps. Both are legitimate; this is ours.

**Is my data actually safe there?**
Photos and passwords are end-to-end encrypted — the person running the server
cannot read them, by design, ever. Backups are nightly, encrypted, off-site,
and restore-tested. And your host is someone you know, accountable to you at
the dinner table — not a support queue.

**What does it cost?**
The software is free and open source. Real costs: the hardware (~a mini-PC), a
domain, and off-site backup storage — typically split across the community.
There's no company here, no accounts, no billing.

**What happens if the hardware dies?**
Backups + a documented rebuild procedure. The recovery runbooks are public in
the repo — judge them yourself.

**Can I leave?**
Yes, and it's documented. Ente exports your originals, Bitwarden vaults export
to standard formats, media files are just files. An alternative you can't leave
is just another landlord.

## Contact / CTA

*[Footer-adjacent, the only conversion point.]*

**Curious? Skeptical? Want in?**
Whether you'd join an existing community or host for your own — start with an
email. **dustindoan@proton.me** *(decided 2026-07-15: maintainer proton address)*

*[Footer links: GitHub · Roadmap · Member setup guide · License (AGPL-3.0)]*

---

## Publication notes (not site content)

- **Built & live:** [site/index.html](../site/index.html) — single hand-written
  HTML/CSS file, no framework, no external requests; light/dark via
  `prefers-color-scheme`, responsive. **Live at <https://coralstack.org/>**;
  `.github/workflows/pages.yml` redeploys on every `site/**` push to `main`
  (Pages enabled, domain verified, HTTPS enforced — the old "publish gate" is
  already crossed). Deploy details: [site/README.md](../site/README.md).
- **Venue (decided):** static single page on GitHub Pages with the
  `coralstack.org` apex — zero coupling to the co-op's production stack, and the
  site staying up is independent of the stack being down (which is the moment
  people check it).
- **Live-claim accuracy** (was the pre-publish checklist; the site is now live, so
  these are public promises, not gates): initial 646 GB photo backup ✅ complete
  (2026-07-22) — the "restore-tested backups" claim no longer overstates on the
  backup-existing front. SEC-1: confirm remediated. Contact address ✅ decided:
  dustindoan@proton.me. If any item is still open, the honest move is to soften
  the live copy, not wait to publish — it's already up.
- **Claims audit:** "restore-tested" = 2026-07-15 DB/config restore test; with the
  646 GB full backup now complete (2026-07-22), the remaining step to make the
  claim fully true is a one-time photo-blob restore verification — confirm that's
  been run. "We document how" (music acquisition) — the member-facing page for
  that doesn't exist yet (gate #2); either finish it or soften to "guidance
  coming."
- **Blog-post seed:** the 2026-06-11 message that shaped the "Something worth
  owning" section (Photos API deprecation → cloud concentration → AI switching
  costs → ownership vs. renting, à la Gary Stevenson on wealth inequality) is a
  launch post waiting to be written. Park it for launch week.
