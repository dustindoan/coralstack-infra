# Launch post — draft v1 (2026-07-22)

Draft of the launch blog post seeded in [SITE_COPY.md](SITE_COPY.md). First-person
maintainer voice. Reuses the "Something worth owning" thesis chain, expanded with
story. Member-first, but the second half turns to the would-be host-admin. Same
voice rules as the landing page: plain, concrete, honest about early-stage, no hype.

Structure notes in *[brackets]*; everything else is copy.

---

## Something worth owning

*[Working title. Alternatives: "The internet you can point to" · "Not a different
landlord" · "Run one for your people."]*

A little while ago I went looking for a way to move my photos out of one company's
cloud and into software I actually controlled. I found the door had quietly closed.
Google had retired its Photos Library API — the interface that let other software
read your own photo library — in 2025. The pictures were still mine, technically.
Getting them somewhere I chose was now someone else's decision.

That's a small thing. But small things rhyme.

### The pattern

Once you notice it, you see the same shape everywhere. The infrastructure that runs
modern life keeps folding into fewer and fewer hands. In Canada, three companies —
Amazon, Google, and Microsoft — now hold
[85% of the cloud market](https://www.cbc.ca/news/business/cloud-computing-competition-9.7219996);
a report this year called it "broken." When one of them hiccups, a chunk of the
internet goes dark with it.

And now the same play is running with AI. Your photos, your passwords, and — more
and more — your actual thinking are moving inside someone else's model, in someone
else's datacenter. Each thing you add raises the cost of ever leaving. That's not
an accident. That's the business model.

Here's the part I keep coming back to. The economist Gary Stevenson makes a blunt
point about money:
[the people who *own* things pull away from the people who *rent* them](https://www.youtube.com/watch?v=iD2sPL7k98c),
and the distance compounds — every year, quietly, in the owners' favour. Digital
life is running that exact script. A few platforms own the infrastructure. Everyone
else rents access to their own memories. And the gap widens on its own.

I don't think the answer to that is a better subscription. A nicer landlord is still
a landlord.

### The good news, which is real

Here's what changed, and why I'm writing this now instead of just complaining.

The tools to opt out finally got good. Open-source software caught up to the paid
stuff — in some cases passed it. End-to-end encryption became something you can turn
on by default instead of a research project. And the hardware to run all of it now
costs less than a year of the subscriptions it replaces, and fits on a shelf. What
used to take a datacenter fits in a room.

So I built the room. **CoralStack** is a small computer, running in a home, that
does the jobs you'd otherwise rent:

- **Photos** — your camera roll, backed up automatically and end-to-end encrypted.
  Not even the server can see them.
- **Passwords** — a full password manager, apps on every device, autofill included.
- **Movies, TV, and music** — your community's library, streaming to every screen.
  Your music collection lives here too — owned, not rented.
- **A private AI assistant** — capable, running on open models, on hardware in the
  building. The conversation never leaves.
- **One login** for all of it — your face or your fingerprint, nothing to phish.

It's not a company. There's no billing, no accounts, no upsell. The whole thing is
open source (AGPL-3.0) and the entire setup — infrastructure, runbooks, backup and
recovery — lives in one public repo you can read before you trust it.

I'll be honest about where it is: **early.** One community runs it today — mine, in
Campbell River. Joining is still high-touch; a real person sets you up. I'd rather
tell you that now than have you find out later. The [roadmap](../ROADMAP.md) and the
open blockers are public for the same reason.

### The part that actually matters

Self-hosting is not new. People have been running their own servers for decades. But
be honest about who it reached: the technical. If you're the kind of person who reads
to the end of a post like this, you can probably solve photos and passwords and AI
for yourself already.

Most people can't. And that's the whole gap. For twenty years this movement freed the
technophiles and left everyone else on the rented internet — the people who don't want
to learn Linux and shouldn't have to. Your parents. Your neighbours. The co-op down
the road.

They don't need to become technical. They need to *know someone who is.*

That's the shape CoralStack is built for. One person's weekend of setup covers a whole
household, a friend group, a co-op — not just themselves. If you're that person — the
one everyone already texts when the wifi breaks — you're the missing piece. Not a
product. A neighbour who happens to run the server.

### If any of this lands

Whether you'd want to join a community like this or **host one for the people around
you**, the door is open — this time on purpose. The code is on
[GitHub](https://github.com/dustindoan/coralstack-infra). Everything else starts with an
email: **dustindoan@proton.me**.

Your photos, on hardware your community owns. It's a small step. But it's the actual
alternative — not a different landlord.

---

*[Post-draft notes:*
- *Repo is `dustindoan/coralstack-infra` (matches index.html) — wired in.*
- *A styled HTML version of this post is staged at
  [blog-drafts/something-worth-owning.html](blog-drafts/something-worth-owning.html),
  outside `site/` so it stays a draft. Publish = move to `site/blog/`, set a real
  date, link from index.html + footer.*
- *Personal origin anecdote (para 1) is written generic; swap in the real moment if
  there's a truer one.*
- *Live TV / Dispatcharr omitted, per site-copy decision — keep it out of the post too.*
- *Same pre-publish caveat as the landing page: the CBC stat is Canada-specific;
  intentional here given the Campbell River framing.]*
