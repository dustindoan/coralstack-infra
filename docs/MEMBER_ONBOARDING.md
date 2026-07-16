# Welcome to CoralStack — member setup guide

This guide gets you from "I got an invite" to photos, passwords, movies, and music
working on your own devices. Budget **about 30 minutes**. No technical background
needed — every step says exactly what to tap.

> **Note for your admin** (members can skip this box): before sending this guide,
> (1) fill in the addresses table below, (2) create the member's Pocket ID user in
> the `members` group, (3) temporarily open Ente registration and be reachable to
> relay the email verification code, and (4) make sure Quick Connect is enabled in
> Jellyfin (Dashboard → General) so the apps in Step 4 can sign in. The technical
> detail behind every step here lives in [ONBOARDING.md](ONBOARDING.md).

## Your addresses

Your admin fills these in — they're the same for everyone in your community, just
with your community's domain. Wherever this guide says `<domain>`, use yours.

| What                | Address                       |
| ------------------- | ----------------------------- |
| Your login (passkey)| `https://id.<domain>`         |
| Passwords           | `https://vault.<domain>`      |
| Photos              | `https://photos.<domain>`     |
| Photos app server   | `https://photos-api.<domain>` |
| TV, movies & music  | `https://media.<domain>`      |
| AI chat             | `https://ai.<domain>`         |
| Is it down?         | `https://status.<domain>`     |
| Your admin          | *(name + phone/email here)*   |

## What you'll need

- Your phone, and a computer if you have one (phone alone works)
- **A pen and a piece of paper.** Two things get written down and kept somewhere
  safe (a drawer, a safe) — they are the keys to your passwords and photos, and
  nobody, including your admin, can recover them for you if they're lost.
- Your admin within reach (in person or by phone) for the photos step

## How signing in works (30 seconds of background)

Almost everything here uses **one login: a passkey**. A passkey is a sign-in that
lives inside your phone or computer and unlocks with your fingerprint or face — no
password to remember, and it can't be phished or guessed. You set it up once in
Step 1, then every service offers a "sign in" button that just asks for your
fingerprint/face.

Two services additionally have their own secret, because they're encrypted so
deeply that even the server can't read your data: your password vault (Step 2)
and your photos (Step 3). Those are the two things that go on paper.

## Step 1 — Set up your passkey (5 min)

1. On the device you use most, open a browser and go to `https://id.<domain>`.
   On iPhone or Mac, **use Safari** — it stores the passkey in your iCloud
   Keychain so it follows you across your Apple devices.
2. Sign in with the details in your invite email.
3. When prompted, **register a passkey** and approve with your fingerprint/face.
4. Prove it works: sign out, then sign back in using the passkey.

That's your login for everything below.

## Step 2 — Set up your password vault (10 min)

Your community runs its own Bitwarden-compatible password manager. It stores every
password you have — for coralstack services and the rest of the internet — and
fills them in automatically.

### First sign-in (do this in a browser first)

1. Go to `https://vault.<domain>` and click **Sign in with SSO** (not the
   email/password boxes). Approve with your passkey.
2. First time only, you'll be asked to create a **master passphrase**. This is one
   of your two paper secrets: pick a phrase of 4–5 random words (the page can
   suggest one), **write it on paper**, and store the paper somewhere safe.
   - Why paper? The vault is encrypted with this passphrase. If it's lost, the
     vault's contents are gone — there is no "forgot passphrase" email.
3. Your vault opens (empty for now). Done with the browser part.

### Install the app on your phone

1. Install **Bitwarden** from the App Store / Play Store.
2. Open it. **Before signing in**, tap the **gear icon at the top of the login
   screen** → choose **Self-hosted** → enter Server URL: `https://vault.<domain>`
   → save. ⚠️ **Don't skip this** — without it the app talks to the wrong
   (public Bitwarden) server and your login fails confusingly.
3. Sign in with SSO (your passkey), then your master passphrase. Turn on
   fingerprint/face unlock when offered.
4. Let it fill passwords for you:
   - **iPhone:** Settings → Passwords → AutoFill Passwords → turn on Bitwarden.
   - **Android:** Bitwarden app → Settings → Auto-fill → turn on the autofill
     service.

### Optional: browser extension on your computer

Install the Bitwarden extension from your browser's extension store, tap its gear
icon on the login screen, and enter the same self-hosted Server URL. Sign in the
same way. (If you also install the Bitwarden **desktop app**, sign in there with
your **email + master passphrase** instead of the SSO button — SSO in the desktop
app doesn't work with our setup yet.)

## Step 3 — Set up your photos (10 min, with your admin)

Photos run on **Ente** — end-to-end encrypted, so only your devices can see your
pictures. Because of that encryption, Ente has its own password instead of the
passkey, and signup is a one-time ritual you do together with your admin (new
account creation is normally switched off).

1. **Arrange a moment with your admin** — they open registration and will read
   you a verification code partway through.
2. In a browser, go to `https://photos.<domain>` → **Sign up**.
3. For the password: open your Bitwarden app, create a new item called "Ente
   Photos", and use its password generator to make a strong password. **Save it
   in Bitwarden first, then paste it into the Ente signup.** You'll retrieve it
   from Bitwarden whenever you set up a new device.
4. Ente asks for a verification code that gets "emailed" to you — on our setup
   your **admin reads you the code** instead. Enter it.
5. Ente shows a **recovery code**. This is your second paper secret: **write it
   down** and store it with the master passphrase paper. It's the only way back
   into your photos if you ever forget the Ente password *and* lose Bitwarden.
6. Now the phone app: install **Ente Photos** from the App Store / Play Store.
7. On the app's sign-in screen, tap the **settings icon in the corner** and set
   the **Server endpoint** to `https://photos-api.<domain>`. ⚠️ Same trap as
   Bitwarden — skip this and you're signing in to the wrong server.
8. Sign in with your email + the Ente password (from Bitwarden). Use **Sign in**,
   not Sign up — account creation only works in the browser on our setup.
9. When the app asks, allow access to your photo library and choose which albums
   to back up. Your camera roll now backs up to your community's server.

## Step 4 — TV, movies & music (5 min)

Movies, shows, live TV, and the shared music library all live in **Jellyfin**.

**In a browser** (easiest, works everywhere): go to `https://media.<domain>`,
click the **Pocket ID / SSO sign-in link**, approve with your passkey. You're in.

**On your phone, tablet, or TV**, use the official **Jellyfin** app (App Store /
Play Store / your TV's app store — skip third-party Jellyfin apps for now, some
don't play well with our server):

1. Open the app → **Add server** → enter `https://media.<domain>`.
2. On the sign-in screen choose **Quick Connect**. The app shows a short code.
3. On a device where you're already signed in to `https://media.<domain>` in the
   browser, click your **user icon (top right) → Quick Connect**, type the code,
   and approve.
4. The app signs itself in. Repeat for each device (TV included).

Music is the **Music** section inside the same Jellyfin app; Live TV is the
**Live TV** section.

## Step 5 — AI chat (optional, 1 min)

Your community also runs a private AI assistant — conversations stay on your
community's server. Go to `https://ai.<domain>`, click **Sign in with Pocket ID**,
done. It works nicely on a phone too (your browser will offer "Add to Home
Screen").

## When something looks broken

1. **Check `https://status.<domain>` first.** It shows, service by service,
   whether the problem is on the server or just on your device.
2. **If status says everything is Up** but an app or site still shows an error:
   your browser is probably showing a cached copy of an old failure. Try a
   **private/incognito window**; if that works, **fully quit and reopen your
   browser** (or the app). That clears it.
3. **If status shows something Down**, or the tricks above don't help: contact
   your admin (top of this guide). Tell them what you tapped and what you saw —
   a photo of the screen is perfect.

## The two pieces of paper (recap)

| Secret | Protects | Where it lives |
| ------ | -------- | -------------- |
| Bitwarden master passphrase | your password vault | paper, somewhere safe |
| Ente recovery code | your photos | paper, same place |
| Ente password | photos sign-in on new devices | inside Bitwarden |
| Passkey | everything else | inside your phone/computer — nothing to write |

Lose the papers and your devices at the same time, and not even your admin can
get the encrypted stuff back. That's the point — it means nobody else can either.
