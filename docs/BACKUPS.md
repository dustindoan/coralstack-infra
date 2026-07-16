# Backups

Nightly, encrypted, deduplicated, **cloud-agnostic** backups of the CoralStack
data — and the runbook for getting it back.

This implements [LAUNCH_BLOCKERS](LAUNCH_BLOCKERS.md) gate #3 and the post-trial
direction in the backup-strategy memory. The pitch is "trust this with your
family's photos and passwords." Without offsite backups, one disk failure is a
launch-killing story — so this is the top infrastructure gap.

> **RAID is not backup.** RAID protects against a drive dying (availability). It
> does nothing about accidental deletion, filesystem corruption, enclosure
> death, theft, fire, or ransomware. This document is about *durability*, which
> is a separate problem.

## How it works

The `backup` service ([services/backup/](../services/backup/)) is a small
custom image — `restic` + `rclone`, scheduled by `supercronic`. Each night it:

1. **Dumps the databases through their own engines** into a staging dir. A raw
   file-copy of a *live* database directory can be torn/inconsistent, so we
   dump instead:
   - **Ente** — `pg_dump` over the `coralstack` network to `ente-postgres`
     (custom format → `ente_db.dump`). No Docker socket needed.
   - **Vaultwarden** — SQLite online `.backup` → `vaultwarden.sqlite`.
   - **Pocket ID** — SQLite online `.backup` → `pocket-id.sqlite`.
2. **Runs `restic backup` as two tagged snapshot streams** (same repo,
   separate retention — see [Schedule & retention](#schedule--retention)):
   - **`data` stream** — `/staging` (the fresh, consistent DB dumps), `/data`
     (every service's config + data, read-only), `/config` (the compose tree
     incl. host-only `.env` secrets)
   - **`storage` stream** — `/storage`: the TerraMaster (`${STORAGE_PATH}`,
     read-only): Ente photo blobs + music
3. **Applies per-stream retention** (`restic forget --tag …` then one
   `restic prune`) and **verifies** the repo structure (`restic check`).

The result is "essentially the whole TerraMaster in one repo" **plus** a
guaranteed-consistent database restore. The database directories under `/data`
are captured too (as a bonus), but the dumps in `/staging` are the authoritative
restore source.

### What's backed up — and what isn't

| Included | Notes |
| --- | --- |
| Ente Postgres + photo blobs (MinIO) | The irreplaceable data. Always backed up. |
| Vaultwarden DB + attachments/sends/keys | Vaults are E2E-encrypted regardless. |
| Pocket ID DB + config | Identity provider. |
| All other service configs under `${DATA_PATH}` | Jellyfin/Dispatcharr/Open WebUI settings, Caddy data, etc. |
| The compose tree (`/config`), incl. gitignored `services/*/.env` | The hand-created secret files exist **only on this host** — without them a rebuild means re-deriving every service secret while Vaultwarden (which holds them) is itself down. |
| **Excluded by default** | **Why** |
| `/storage/music`, `/storage/movies`, `/storage/shows` (media libraries) | Large and *re-acquirable* — members keep originals; music is re-rippable/re-downloadable; recordings can be re-captured. Sending TBs to metered cloud buys no durability. Flip `BACKUP_EXCLUDES` to include them. |
| `/data/jellyfin/cache` | Transient transcode/image cache. |
| `/data/backup` | Our own staging + cache + local repo — never capture ourselves. |
| `/config/data`, `/config/.git` | `/config/data` is the same tree as `/data`; git history lives on GitHub. |

> ⚠️ **Never exclude `/storage` wholesale.** It reads like "skip the big media
> dirs" but it also silently drops the Ente photo blobs — the one thing the
> backup exists for. The repo staying suspiciously small (a few GiB) is the
> tell. The 2026-07-15 restore test caught exactly this in production; see the
> restore-test log below.

Caddy TLS certs are deliberately **not** treated as precious — they re-issue via
DNS-01 if lost. Proxmox/OPNsense config is out of scope here (OPNsense config
export is a separate manual step; see the backup-strategy memory).

## The destination is a config knob (no vendor lock-in)

`restic`'s repository format is open and encrypted; `rclone` lets it target
almost any provider — or a box you own — purely from env vars. Switching
providers never means re-architecting. The provider only ever sees opaque
encrypted blobs, which is the only reason a third-party cloud is acceptable
under our "no vendor in the data path" principle.

Set `RESTIC_REPOSITORY` in [services/backup/.env](../services/backup/.env.example):

**Local path (default).** `RESTIC_REPOSITORY=/repo`, mounted from
`${BACKUP_REPO_PATH}` (root `.env`, defaults to `${DATA_PATH}/backup/repo`).
This proves the mechanism and gives you a restore-testable repo out of the box —
but it's on the **same host as the data**, so on its own it is **not real
durability**. Point `BACKUP_REPO_PATH` at a separate drive, or use an offsite
remote below, for an actual backup.

**Offsite via rclone.** Set `RESTIC_REPOSITORY=rclone:offsite:<bucket>` and
configure the `offsite` remote with `RCLONE_CONFIG_*` env vars. Examples for
Backblaze B2, Wasabi/R2/S3, and SFTP (rsync.net / a friend's box / a co-op
member) are in [services/backup/.env.example](../services/backup/.env.example).

### 3-2-1 mapping

| Copy | This setup |
| --- | --- |
| 1 — primary | Live data on the TerraMaster |
| 2 — different media | Local restic repo on a **separate drive** (set `BACKUP_REPO_PATH`) |
| 3 — offsite | A second restic target via `rclone` (B2/Wasabi/SFTP/member) |

To run **both** a local copy and an offsite copy, the simplest pattern is to
back up locally, then `restic copy` to the offsite repo (same format, dedup
preserved). Documented as a follow-up; for the launch gate one offsite repo
satisfies "backups exist + restore tested."

## Schedule & retention

- **Schedule:** `BACKUP_CRON` (default `15 3 * * *` — 03:15 in the container
  TZ). The Ente janitor purges deleted photo blobs *after* this runs (05:30) —
  the ordering is load-bearing; see [ENTE_STORAGE.md](ENTE_STORAGE.md).
- **Retention (per stream):**

  | Stream | Env | Default | Why |
  | ------ | --- | ------- | --- |
  | `data` (dumps, configs, secrets) | `RESTIC_KEEP_DAILY/WEEKLY/MONTHLY` | 7 / 4 / 6 | Tiny; deep history is cheap and every version matters. |
  | `storage` (photo blobs) | `RESTIC_STORAGE_KEEP_DAILY/WEEKLY/MONTHLY` | 7 / 4 / 0 | Blobs are append-then-delete and client-side encrypted (no dedup across re-uploads). A short tail bounds how long deleted-photo churn lingers in the repo (~a month, vs ~7 months with monthlies). Set a value to 0 to omit that tier. |

  `forget` runs per tag, then a single `prune` reclaims space.

### Migrating from single-stream snapshots (pre-2026-07-16)

Snapshots taken before the stream split carry the old `coralstack` tag and are
matched by **neither** per-stream `forget`, so they'd linger forever. After the
split has a few days of history, list and drop them once:

```bash
docker exec backup restic snapshots --tag coralstack   # legacy only — new streams are tagged data/storage
docker exec backup restic forget --prune <legacy snapshot IDs>
```

## Manual operations

```bash
# Run a backup right now (same script the scheduler runs):
docker exec backup backup.sh

# List snapshots:
docker exec backup restic snapshots

# Deep integrity check — actually re-reads a sample of the data (slower; the
# nightly run only checks structure). Do this periodically.
docker exec backup restic check --read-data-subset=5%

# Browse what's in the latest snapshot:
docker exec backup restic ls latest
```

## Restore

> Restores run from the `backup` container, which already has the repository
> credentials in its environment. For a **bare-metal disaster recovery** (host
> is gone), you instead need the repo, the `RESTIC_PASSWORD`, and any
> `RCLONE_CONFIG_*` values — see "Disaster recovery" below.

### Restore files from a snapshot

> Snapshots come in two tagged streams (`data` and `storage`); a bare
> `latest` resolves to whichever ran last, so **always pass `--tag`**.

```bash
# Restore the data tree (dumps + configs + secrets) into a scratch dir:
docker exec backup restic restore latest --tag data --target /staging/restore

# Or just one path:
docker exec backup restic restore latest --tag data --include /staging/db --target /staging/restore

# Photo blobs live in the storage stream:
docker exec backup restic restore latest --tag storage --include /storage/ente-minio --target /staging/restore
```

### Per-service restore

**Ente (Postgres):** copy the dump out and `pg_restore` into a fresh DB.

```bash
docker exec backup restic restore latest --tag data --include /staging/db/ente_db.dump --target /staging/restore
docker cp backup:/staging/restore/staging/db/ente_db.dump /tmp/ente_db.dump
# Stop museum so nothing writes during the restore, then restore into ente-postgres:
docker stop ente-museum
docker cp /tmp/ente_db.dump ente-postgres:/tmp/ente_db.dump
docker exec -e PGPASSWORD="$ENTE_DB_PASSWORD" ente-postgres \
  pg_restore -U ente -d ente_db --clean --if-exists /tmp/ente_db.dump
docker start ente-museum
```

**Ente (photo blobs):** the MinIO blobs live under `${STORAGE_PATH}/ente-minio`
and are restored as files (they're inside the **`storage`-stream** snapshot
under `/storage/ente-minio`). Restore that path (`--tag storage`) and copy it
back into place, then restart `ente-minio`.

**Vaultwarden / Pocket ID (SQLite):** restore the `.sqlite` file and drop it in
place (service stopped), e.g. for Vaultwarden:

```bash
docker exec backup restic restore latest --tag data --include /staging/db/vaultwarden.sqlite --target /staging/restore
docker stop vaultwarden
docker cp backup:/staging/restore/staging/db/vaultwarden.sqlite vaultwarden:/data/db.sqlite3
docker start vaultwarden
```

### Disaster recovery (host is gone)

1. Provision a fresh host and clone the repo; run `./setup.sh` to scaffold.
2. Restore the **`RESTIC_PASSWORD`** (from paper in the safe — Tier-1 secret)
   and any `RCLONE_CONFIG_*` provider creds into `services/backup/.env`, and
   point `RESTIC_REPOSITORY` at the surviving (offsite) repo.
3. `docker compose up -d backup`, then `docker exec backup restic snapshots` to
   confirm access.
4. **Recover the service secrets first**: restore `/config` from the snapshot
   and copy every `services/*/.env` (plus the root `.env`) back into the fresh
   checkout. This breaks the bootstrap circle — the secrets are otherwise in
   Vaultwarden, which is itself one of the services you're trying to restore.
   ```bash
   docker exec backup restic restore latest --tag data --include /config --target /staging/restore
   # then copy /staging/restore/config/services/*/.env into place
   ```
5. Restore each service's data per the steps above **before** bringing the
   rest of the stack up against empty volumes.

## Restore test (the gate)

A backup you have never restored is an aspiration, not a backup. The gate for
"backups are done" is **one successful restore from the repo to a scratch
location**. Procedure:

```bash
# 1. Take a fresh backup and confirm a snapshot exists.
docker exec backup backup.sh
docker exec backup restic snapshots

# 2. Restore the data stream to a scratch target and confirm the dumps are intact.
docker exec backup restic restore latest --tag data --target /staging/restore
docker exec backup ls -la /staging/restore/staging/db
#    Expect: ente_db.dump, vaultwarden.sqlite, pocket-id.sqlite (non-zero size).

# 3. Prove the Postgres dump is actually loadable (not just present):
docker exec backup sh -c \
  'pg_restore --list /staging/restore/staging/db/ente_db.dump | head'
#    A table-of-contents listing = the dump is valid and restorable.

# 4. Prove a SQLite dump opens and has the expected schema:
docker exec backup sqlite3 /staging/restore/staging/db/vaultwarden.sqlite '.tables'

# 5. Prove the storage stream actually contains photo blobs (this is the check
#    that catches an excludes regression like 2026-07-15's):
docker exec backup sh -c 'restic ls latest --tag storage /storage/ente-minio | head'

# 6. Clean up the scratch restore.
docker exec backup rm -rf /staging/restore
```

Run a full restore test **quarterly** (add to the admin agent's duties once
lettabot is operational). Record the date and outcome.

### Restore-test log

| Date | Outcome |
| --- | --- |
| 2026-07-15 | **Dumps: PASS. Coverage: FAIL — test caught a critical gap.** Fresh backup + full scratch restore ran clean; `ente_db.dump` (110 MB) listed valid via `pg_restore --list`, `vaultwarden.sqlite` + `pocket-id.sqlite` opened with expected schemas. But the restore contained **no `/storage` tree**: the deployed `.env` had `BACKUP_EXCLUDES=…,/storage` (vs the documented `/storage/music`), so **646 GB of Ente photo blobs had never been in any snapshot** — repo was 2.5 GiB total. Also found: hand-created `services/*/.env` secrets weren't captured (fixed by the `/config` mount, this change). Remediation: corrected `BACKUP_EXCLUDES` on the box, redeploy + initial ~646 GB B2 upload pending. |

## Secrets

`RESTIC_PASSWORD` is a **Tier-1 secret**: lose it and the repository is
mathematically unrecoverable — every backup is gone. `setup.sh` generates one on
first run and warns you to record it. **Copy it to paper in the safe**, not just
`services/backup/.env` on the very host the backups are meant to survive:

```bash
grep '^RESTIC_PASSWORD=' services/backup/.env
```

Provider credentials (`RCLONE_CONFIG_*`) are Tier-2 (Vaultwarden) — losing them
costs access to the *destination*, not the data, and they can be re-issued.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `ENTE_DB_PASSWORD unset — skipping Ente Postgres dump` | `services/ente/.env` missing or Ente not deployed. The compose reads it via `env_file: ../ente/.env`. |
| `unable to open repository` on an rclone target | Check `RCLONE_CONFIG_*` env vars; test with `docker exec backup rclone lsd offsite:`. |
| `repository is already locked` | A previous run died mid-flight. `docker exec backup restic unlock`. |
| Backup runs but nobody notices it failed | Set `HEALTHCHECK_URL` to a healthchecks.io / Uptime Kuma push URL (dead-man's-switch). |
| Repo bloats unexpectedly | Confirm `BACKUP_EXCLUDES` covers music; check `docker exec backup restic stats`. |

## Follow-ups (not gating launch)

- `restic copy` to a second (offsite) repo for true 3-2-1 in one run.
- Wire `HEALTHCHECK_URL` to the monitoring of record.
- OPNsense config export into the backup set.
- Promote quarterly restore-test + read-data verification into lettabot duties.
