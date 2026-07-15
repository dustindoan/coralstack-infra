# /// script
# requires-python = ">=3.10"
# dependencies = ["streamrip==2.1.0"]
# ///
"""Qobuz purchases-only fetcher (v0) — download what you OWN into staging.

The clean-by-construction Qobuz lane from docs/MUSIC_ACQUISITION.md: this
enumerates `purchase/getUserPurchases` and can therefore only ever download
items you paid for (the same flow as the official Downloader, headless).
It is NOT a stream-ripper and must never be pointed at streamable content.

v0 is a one-shot: run it after buying, files land in the staging dir, the
music-ingest container does the rest. The containerized poll loop (front
half) builds on this same code later.

Usage:
    QOBUZ_TOKEN=<web-session token>  uv run services/music/qobuz-fetch.py [DEST]

DEST defaults to ./staging-out (locally); on the server point it at
${STORAGE_PATH}/music-staging. Existing files are skipped, so re-runs are
cheap and idempotent.
"""

import asyncio
import hashlib
import os
import re
import sys
import time

import aiohttp
from streamrip.client.qobuz import QobuzSpoofer

API = "https://www.qobuz.com/api.json/0.2"

# Qobuz download-quality ladder, best-first. format_id meanings:
#   27 = FLAC 24-bit >96kHz (up to 192)   6 = FLAC 16-bit/44.1 (CD)
#    7 = FLAC 24-bit <=96kHz               5 = MP3 320
# IMPORTANT (verified 2026-07-15): with a web-session token + the spoofed
# web-player app_id, `intent=download` for format 27 is refused
# (TrackRestrictedByPurchaseCredentials) EVEN for a hi-res purchase — only the
# official Downloader's app credentials unlock the 192kHz tier. Format 7
# (24/96) downloads cleanly. So we try 27 (works if creds ever allow it),
# then settle for 7, then 6. See docs/MUSIC_ACQUISITION.md "quality ceiling".
FORMAT_LADDER = [27, 7, 6]


def sanitize(name: str) -> str:
    """Make a string safe as a single path component."""
    return re.sub(r'[/\\:*?"<>|]', "_", name).strip().rstrip(".")


async def api_get(session: aiohttp.ClientSession, endpoint: str, params: dict):
    async with session.get(f"{API}/{endpoint}", params=params) as resp:
        return resp.status, await resp.json(content_type=None)


async def signed_file_url(session, app_id, secrets, track_id):
    """track/getFileUrl(intent=download), best obtainable quality.

    Walks FORMAT_LADDER; for each format tries every candidate secret (400 =
    bad signature → wrong secret). Returns the first response that actually
    carries a download URL, so restricted higher tiers fall through to the
    best quality this account's credentials can actually download.
    """
    last = (None, None)
    for format_id in FORMAT_LADDER:
        for secret in secrets:
            ts = time.time()
            sig = f"trackgetFileUrlformat_id{format_id}intentdownloadtrack_id{track_id}{ts}{secret}"
            status, resp = await api_get(
                session,
                "track/getFileUrl",
                {
                    "request_ts": ts,
                    "request_sig": hashlib.md5(sig.encode()).hexdigest(),
                    "track_id": track_id,
                    "format_id": format_id,
                    "intent": "download",
                },
            )
            if status == 400:  # wrong secret, try next
                continue
            if resp.get("url") and not resp.get("sample"):
                return status, resp
            last = (status, resp)  # e.g. restricted tier; try lower quality
            break
    return last


async def download(session: aiohttp.ClientSession, url: str, dest: str) -> int:
    tmp = dest + ".part"
    total = 0
    async with session.get(url) as resp:
        resp.raise_for_status()
        with open(tmp, "wb") as f:
            async for chunk in resp.content.iter_chunked(1 << 17):
                f.write(chunk)
                total += len(chunk)
    os.rename(tmp, dest)  # only ever expose complete files to the watcher
    return total


async def main() -> int:
    token = os.environ.get("QOBUZ_TOKEN")
    if not token:
        print(__doc__)
        print("✘ QOBUZ_TOKEN not set")
        return 2
    dest_root = sys.argv[1] if len(sys.argv) > 1 else "./staging-out"
    os.makedirs(dest_root, exist_ok=True)

    async with QobuzSpoofer() as spoofer:
        app_id, secrets = await spoofer.get_app_id_and_secrets()

    headers = {"X-App-Id": str(app_id), "X-User-Auth-Token": token}
    fetched = skipped = failed = 0
    async with aiohttp.ClientSession(headers=headers) as session:
        status, resp = await api_get(
            session,
            "purchase/getUserPurchases",
            {"app_id": str(app_id), "limit": 500, "offset": 0},
        )
        if status != 200:
            print(f"✘ getUserPurchases: HTTP {status} — {resp.get('message')}")
            print("  (401 here usually means the token expired — re-extract from a")
            print("   logged-in play.qobuz.com session; see docs/MUSIC_ACQUISITION.md)")
            return 1

        albums = resp.get("albums", {}).get("items", [])
        loose = resp.get("tracks", {}).get("items", [])
        print(f"Purchases: {len(albums)} album(s), {len(loose)} loose track(s)")

        # (album_dir, track) work list — albums plus loose tracks.
        work: list[tuple[str, dict]] = []
        for a in albums:
            status, full = await api_get(
                session, "album/get", {"app_id": str(app_id), "album_id": a["id"]}
            )
            if status != 200:
                print(f"  ✘ album/get {a.get('title')}: HTTP {status}")
                failed += 1
                continue
            artist = sanitize(a.get("artist", {}).get("name", "Unknown Artist"))
            album_dir = os.path.join(dest_root, f"{artist} - {sanitize(a['title'])}")
            for t in full.get("tracks", {}).get("items", []):
                work.append((album_dir, t))
        for t in loose:
            work.append((os.path.join(dest_root, "Loose Tracks"), t))

        for album_dir, t in work:
            n = t.get("track_number", 0)
            fname = f"{n:02d} {sanitize(t.get('title', str(t['id'])))}.flac"
            path = os.path.join(album_dir, fname)
            if os.path.exists(path):
                skipped += 1
                continue
            status, resp = await signed_file_url(session, app_id, secrets, str(t["id"]))
            if status != 200 or resp.get("sample") or not resp.get("url"):
                print(f"  ✘ {fname}: HTTP {status} sample={resp.get('sample')}")
                failed += 1
                continue
            os.makedirs(album_dir, exist_ok=True)
            size = await download(session, resp["url"], path)
            bd, sr = resp.get("bit_depth"), resp.get("sampling_rate")
            print(f"  ✔ {fname} ({size / 1e6:.1f} MB, {bd}bit/{sr}kHz)")
            fetched += 1

    print(f"\nDone: {fetched} fetched, {skipped} already present, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
