# /// script
# requires-python = ">=3.10"
# dependencies = ["streamrip==2.1.0"]
# ///
"""Qobuz purchases-API probe — the gating check for the automated Qobuz lane.

Answers the three make-or-break questions from docs/MUSIC_ACQUISITION.md
WITHOUT touching the broken `user/login` endpoint (401 for password AND
token params since ~2026-04, streamrip #954/#956):

  1. Does a web-session auth token work against the API at all?
  2. Can we enumerate purchases (purchase/getUserPurchases)?
  3. Does track/getFileUrl(intent=download) serve a purchased file?

Auth: log in at https://play.qobuz.com in a browser, then grab the token —
DevTools → Network → filter "login" (re-login if needed) → response JSON
field `user_auth_token`; or search localStorage for a `user_auth_token`
value. Then:

    QOBUZ_TOKEN=<token> uv run services/music/qobuz-probe.py

app_id/secret are auto-extracted from Qobuz's public web bundle (streamrip's
QobuzSpoofer). This probe only ever requests items in YOUR purchase list.
"""

import asyncio
import hashlib
import os
import sys
import time

import aiohttp
from streamrip.client.qobuz import QobuzSpoofer

API = "https://www.qobuz.com/api.json/0.2"

# format_id: 5=MP3 320, 6=FLAC 16/44.1, 7=FLAC 24<=96kHz, 27=FLAC 24/>96kHz
FLAC_16 = 6
FLAC_96 = 7
FLAC_HIRES = 27


def ok(msg: str) -> None:
    print(f"  \033[32m✔\033[0m {msg}")


def fail(msg: str) -> None:
    print(f"  \033[31m✘\033[0m {msg}")


async def api_get(session: aiohttp.ClientSession, endpoint: str, params: dict):
    async with session.get(f"{API}/{endpoint}", params=params) as resp:
        return resp.status, await resp.json(content_type=None)


async def get_file_url(
    session: aiohttp.ClientSession,
    track_id: str,
    secret: str,
    format_id: int,
    intent: str,
):
    ts = time.time()
    sig = f"trackgetFileUrlformat_id{format_id}intent{intent}track_id{track_id}{ts}{secret}"
    return await api_get(
        session,
        "track/getFileUrl",
        {
            "request_ts": ts,
            "request_sig": hashlib.md5(sig.encode()).hexdigest(),
            "track_id": track_id,
            "format_id": format_id,
            "intent": intent,
        },
    )


async def main() -> int:
    token = os.environ.get("QOBUZ_TOKEN")
    if not token:
        print(__doc__)
        fail("QOBUZ_TOKEN not set")
        return 2

    print("[1/4] Extracting app_id + secrets from Qobuz web bundle…")
    async with QobuzSpoofer() as spoofer:
        app_id, secrets = await spoofer.get_app_id_and_secrets()
    ok(f"app_id={app_id}, {len(secrets)} candidate secret(s)")

    headers = {"X-App-Id": str(app_id), "X-User-Auth-Token": token}
    async with aiohttp.ClientSession(headers=headers) as session:
        print("[2/4] Validating token (user/get)…")
        status, resp = await api_get(session, "user/get", {"app_id": str(app_id)})
        if status != 200:
            fail(f"token rejected: HTTP {status} — {resp.get('message')}")
            print("      → re-extract a fresh token from a logged-in web session")
            return 1
        ok(f"token valid for account: {resp.get('email', resp.get('id', '?'))}")

        print("[3/4] Enumerating purchases (purchase/getUserPurchases)…")
        status, resp = await api_get(
            session,
            "purchase/getUserPurchases",
            {"app_id": str(app_id), "limit": 500, "offset": 0},
        )
        if status != 200:
            fail(f"HTTP {status} — {resp.get('message')}")
            return 1
        albums = resp.get("albums", {}).get("items", [])
        tracks = resp.get("tracks", {}).get("items", [])
        ok(f"purchases enumerable: {len(albums)} album(s), {len(tracks)} loose track(s)")
        for a in albums[:10]:
            hires = " [hi-res]" if a.get("hires_purchased") else ""
            print(f"      - {a.get('artist', {}).get('name')} — {a.get('title')}{hires}")

        print("[4/4] Fetching signed URL for a PURCHASED track (intent=download)…")
        track = None
        if albums:
            status, full = await api_get(
                session,
                "album/get",
                {"app_id": str(app_id), "album_id": albums[0]["id"]},
            )
            if status == 200:
                items = full.get("tracks", {}).get("items", [])
                track = items[0] if items else None
        elif tracks:
            track = tracks[0]
        if track is None:
            fail("no purchases on this account — buy one album, then re-run to finish the probe")
            return 1

        # Walk the format ladder best-first and report the highest tier that
        # returns an actual download URL. A tier can come back HTTP 200 with
        # metadata but NO url + a `restrictions` list (e.g. format 27 hi-res
        # is refused for `intent=download` with web-player credentials) — that
        # is NOT a pass. Only a real url counts.
        granted = None
        for fmt in (FLAC_HIRES, FLAC_96, FLAC_16):
            for secret in secrets:
                status, resp = await get_file_url(
                    session, str(track["id"]), secret, fmt, "download"
                )
                if status == 400:  # bad signature → wrong secret, try next
                    continue
                break
            if status != 200:
                continue
            if resp.get("url") and not resp.get("sample"):
                granted = (fmt, resp)
                break
            rc = [r.get("code") for r in (resp.get("restrictions") or [])]
            print(f"      format {fmt}: no download url (restrictions={rc}) — trying lower tier")
        if granted is None:
            fail("no format returned a downloadable url — entitlement check FAILED")
            return 1
        fmt, resp = granted
        ok(
            f"full file granted: '{track.get('title')}' "
            f"{resp.get('bit_depth')}bit/{resp.get('sampling_rate')}kHz "
            f"(format_id {fmt})"
        )
        if fmt != FLAC_HIRES and albums and albums[0].get("hires_purchased"):
            print(
                "      NOTE: this is a hi-res PURCHASE but the top 24/192 tier "
                "(format 27) was refused for download —\n"
                "      web-player credentials cap downloads at 24/96. See "
                "docs/MUSIC_ACQUISITION.md 'quality ceiling'."
            )
        print("\nGATE PASSED — the headless purchases-only fetcher is buildable.")
        return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
