#!/usr/bin/env python3
"""CoralStack admin panel — a tiny action panel for the admin plane.

Deliberately boring: Python stdlib http.server + shelling out to psql. No
framework, no pip installs, no JS — the whole supply chain is this file plus
the Alpine psql client. It is the seed of the Phase 1.5 "admin front door"
(see the admin-dashboard memory / ADMIN_ACCESS.md): read-only gauges plus a
small registry of explicit, confirmed actions.

SECURITY MODEL: the container publishes on 127.0.0.1 only (see compose file);
reach it through the established SSH tunnel. There is no login of its own —
possession of SSH to the box IS the admin credential (same posture as the
loopback rule in ADMIN_ACCESS.md). Two hardenings on top:
  - POSTs with a cross-site Origin/Sec-Fetch-Site are rejected, so a malicious
    website in the admin's browser can't CSRF localhost while the tunnel is up.
  - Every action requires a ticked confirmation checkbox.

Actions run against museum's Postgres `queue` table only — never MinIO,
never blob data. See docs/ENTE_STORAGE.md for what "expedite" means.
"""

import html
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PORT = 8080
DAY_US = 24 * 60 * 60 * 1_000_000

PENDING_SQL = f"""
SELECT count(*)
    || '|' || coalesce(sum(ok.size), 0)
    || '|' || coalesce(floor(max(now_utc_micro_seconds() - q.created_at) / 86400000000.0), 0)
    || '|' || count(*) FILTER (WHERE q.created_at <= now_utc_micro_seconds() - (45::bigint * {DAY_US}))
FROM queue q
LEFT JOIN object_keys ok ON ok.object_key = q.item
WHERE q.queue_name = 'deleteObject' AND q.is_deleted = false;
"""

# The documented Ente workaround: backdate queue items so museum's own cleanup
# cron (every 8 min, <=5000 objects/run) purges them on its next passes.
# https://ente.com/help/self-hosting/troubleshooting/misc
EXPEDITE_SQL = f"""
WITH marked AS (
    UPDATE queue
    SET created_at = now_utc_micro_seconds() - (46::bigint * {DAY_US})
    WHERE queue_name = 'deleteObject' AND is_deleted = false
      AND created_at > now_utc_micro_seconds() - (45::bigint * {DAY_US})
    RETURNING 1
) SELECT count(*) FROM marked;
"""


def psql_ente(sql: str) -> str:
    password = os.environ.get("ENTE_DB_PASSWORD")
    if not password:
        raise RuntimeError(
            "ENTE_DB_PASSWORD is not set — is services/ente/.env present? "
            "(the compose reads it via env_file)"
        )
    proc = subprocess.run(
        ["psql", "-h", "ente-postgres", "-U", "ente", "-d", "ente_db",
         "-v", "ON_ERROR_STOP=1", "-qAt", "-c", sql],
        env={**os.environ, "PGPASSWORD": password},
        capture_output=True, text=True, timeout=30,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"psql failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


def human_bytes(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def pending_stats() -> dict:
    count, size, oldest, eligible = psql_ente(PENDING_SQL).split("|")
    return {
        "count": int(count),
        "bytes": int(size),
        "oldest_days": int(float(oldest)),
        "eligible": int(eligible),
    }


PAGE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CoralStack admin</title>
<style>
  body {{ font: 16px/1.5 -apple-system, system-ui, sans-serif; margin: 2rem auto;
         max-width: 42rem; padding: 0 1rem; color: #1a2b3c; background: #f7f9fa; }}
  h1 {{ font-size: 1.3rem; }} h2 {{ font-size: 1.05rem; margin-top: 2rem; }}
  table {{ border-collapse: collapse; width: 100%; }}
  td, th {{ text-align: left; padding: .35rem .75rem .35rem 0;
            border-bottom: 1px solid #dde4e8; }}
  .num {{ font-variant-numeric: tabular-nums; }}
  .flash {{ padding: .75rem 1rem; border-radius: 6px; margin: 1rem 0;
            background: #e7f4ec; border: 1px solid #b7dfc5; }}
  .flash.err {{ background: #fbeaea; border-color: #eec4c4; }}
  form {{ margin: 1rem 0; padding: 1rem; border: 1px solid #dde4e8;
          border-radius: 6px; background: #fff; }}
  button {{ padding: .45rem 1rem; border: 0; border-radius: 6px;
            background: #b3452e; color: #fff; font-size: 1rem; cursor: pointer; }}
  small, .muted {{ color: #5b6b78; }}
</style></head><body>
<h1>CoralStack admin</h1>
{flash}
<h2>Ente — purge-pending deletions</h2>
<p class="muted">Objects emptied from trash that museum hasn't purged from
disk yet. Quota no longer counts them; only the janitor window (or the button
below) frees the disk. <a href="/">refresh</a></p>
{stats}
<form method="post" action="/expedite">
  <p><strong>Expedite all pending deletions now.</strong><br>
  <small>Backdates every queued item past the 45-day mark; museum's cleanup
  cron then purges from MinIO at ≤5000 objects per 8-minute run. Use after a
  deliberate <em>empty trash</em> (test churn) — this forfeits the remaining
  recovery buffer for those objects, leaving the nightly backups as the only
  way back. Runbook: docs/ENTE_STORAGE.md.</small></p>
  <label><input type="checkbox" name="confirm" value="yes">
  I emptied trash on purpose and want the disk back</label><br><br>
  <button>Expedite deletion queue</button>
</form>
<p><small>Admin plane: 127.0.0.1 only, reached over SSH tunnel
(docs/ADMIN_ACCESS.md). Scheduled purge policy: services/ente-janitor.</small></p>
</body></html>"""


def stats_table() -> str:
    try:
        s = pending_stats()
    except Exception as exc:  # surface DB trouble in the page, not a 500
        return f'<div class="flash err">stats unavailable: {html.escape(str(exc))}</div>'
    eta_runs = -(-s["eligible"] // 5000) if s["eligible"] else 0
    return f"""<table>
<tr><td>Pending objects</td><td class="num">{s['count']:,}</td></tr>
<tr><td>Pending size on disk</td><td class="num">{human_bytes(s['bytes'])}</td></tr>
<tr><td>Oldest pending item</td><td class="num">{s['oldest_days']} day(s)</td></tr>
<tr><td>Already eligible for purge</td><td class="num">{s['eligible']:,}
  <span class="muted">(~{eta_runs} cleanup run(s) × 8 min)</span></td></tr>
</table>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "coralstack-admin"

    def _respond(self, body: str, status: int = 200) -> None:
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def _cross_site(self) -> bool:
        # Forms can't set custom headers, but browsers do send Origin on
        # cross-origin POSTs and Sec-Fetch-Site on modern ones. Same-origin
        # posts from the tunnel (localhost:<port>) pass; a random website
        # trying to CSRF 127.0.0.1 does not.
        origin = self.headers.get("Origin")
        if origin and origin != "null":
            host = urlsplit(origin).hostname
            if host not in ("localhost", "127.0.0.1"):
                return True
        elif origin == "null":
            return True
        sfs = self.headers.get("Sec-Fetch-Site")
        if sfs and sfs not in ("same-origin", "none"):
            return True
        return False

    def do_GET(self) -> None:
        if urlsplit(self.path).path != "/":
            self._respond("<p>not found — <a href='/'>panel</a></p>", 404)
            return
        self._respond(PAGE.format(flash="", stats=stats_table()))

    def do_POST(self) -> None:
        if urlsplit(self.path).path != "/expedite":
            self._respond("<p>not found — <a href='/'>panel</a></p>", 404)
            return
        if self._cross_site():
            self._respond("<p>cross-site request rejected</p>", 403)
            return
        length = int(self.headers.get("Content-Length") or 0)
        form = parse_qs(self.rfile.read(length).decode())
        if form.get("confirm") != ["yes"]:
            flash = '<div class="flash err">Not run — the confirmation box was not ticked.</div>'
            self._respond(PAGE.format(flash=flash, stats=stats_table()))
            return
        try:
            expedited = int(psql_ente(EXPEDITE_SQL))
            flash = (f'<div class="flash">Expedited <strong>{expedited:,}</strong> objects. '
                     f"Museum's cleanup cron picks them up within ~8 minutes; watch "
                     f"<code>docker logs -f ente-museum</code> and disk usage on "
                     f"<code>/storage/ente-minio</code>.</div>")
        except Exception as exc:
            flash = f'<div class="flash err">Expedite failed: {html.escape(str(exc))}</div>'
        self._respond(PAGE.format(flash=flash, stats=stats_table()))

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[admin-panel] %s - %s\n" % (self.address_string(), fmt % args))


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"[admin-panel] listening on :{PORT} (publish 127.0.0.1 only — see compose)", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
