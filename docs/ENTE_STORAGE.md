# Ente storage lifecycle — deletion, disk, and the janitor

Why deleting photos in Ente doesn't free disk, what bounds the growth, and the
runbook for getting disk back on demand (test churn especially).

## The pipeline (what upstream actually does)

Verified against museum source (`server/pkg/repo/queue.go`,
`pkg/controller/trash.go`, `pkg/controller/file.go`):

```
delete in app ──► trash (30 days, user-restorable, COUNTS against quota)
   │ "empty trash" (or 30-day auto-purge)
   ▼
file records deleted, quota freed immediately  ◄── Ente now REPORTS less usage
object keys → `deleteObject` queue              ◄── but MinIO disk is UNCHANGED
   │ hard-coded 45-day delay (no config knob; verified still hard-coded upstream)
   ▼
museum cleanup cron (every 8 min, ≤5000 objects/run) deletes from MinIO
   ▼
disk actually freed
```

Two consequences:

1. **The gap is normal.** Ente reporting X GB while MinIO holds much more is
   the queue, not a bug.
2. **Nothing bounds the purge-pending pool.** Quota is enforced at upload
   against live+trash usage only — emptied blobs count against *nothing* for
   45 days. Upload/delete churn can hold disk unbounded (worst case ≈ 45 days
   × delete rate). That's unacceptable on a fixed-size host, hence:

## The policy

Three pieces, deployed together (decided 2026-07-16):

| Piece | What | Where |
| ----- | ---- | ----- |
| **Janitor** | Daily scoped backdate of `deleteObject` queue items older than `JANITOR_MIN_AGE_DAYS` (default **2**), shrinking the effective purge window from 45 days to N. Runs **after** the nightly backup. | [services/ente-janitor](../services/ente-janitor/) |
| **Backup retention split** | `/storage` blobs get their own restic stream with a short tail (7d/4w/0m) so churn that reaches B2 ages out in ~a month, while DB dumps/configs keep deep history. | [services/backup](../services/backup/), [BACKUPS.md](BACKUPS.md) |
| **Manual expedite** | "Empty trash → get the disk back now" for deliberate mass deletions (test churn) — a button on the admin panel, or one `docker exec`. | [services/admin-panel](../services/admin-panel/) |

**Why this is safe.** Ente's 45-day queue is a last-resort recovery net (e.g.
a compromised account empties trash). We don't remove the net — we *move* it:
the janitor runs post-backup with N≥1, so every purged blob was captured by at
least one nightly snapshot first. Recovery coverage becomes the restic history
(offsite, admin-controlled, ~a month for blobs) instead of 45 days of local
dead weight. The user-facing oops-net (30-day in-app trash) is untouched.

**The ordering invariant:** backup 03:15 → janitor 05:30. If you change either
schedule, keep backup-before-janitor with slack, and keep
`JANITOR_MIN_AGE_DAYS ≥ 1` — the janitor refuses to run below 1 because blobs
could then be purged before any snapshot saw them (no recovery path at all).
Note the mirror image: anything you expedite manually *before* that night's
backup never reaches a snapshot. For test churn that's a feature (zero backup
footprint); for member data it's the reason the button is confirm-gated.

**Mass testing still belongs on a scratch instance.** The janitor bounds the
window; it doesn't make production churn free — expedited-but-snapshotted test
blobs still ride B2 for the storage-stream retention. A staging Ente stack
whose MinIO path sits in `BACKUP_EXCLUDES` stays the right home for repeated
full-library test runs.

## Runbook: reclaim disk after a deliberate mass delete

1. **In the Ente app:** delete the items, then **Uncategorized → Trash →
   Empty trash** (per account involved). Museum frees quota within ~a minute;
   disk does not move yet.
2. **Expedite** (either):
   - **Admin panel:** `ssh -L 9090:localhost:9090 coralstack-apps`, open
     <http://localhost:9090>, tick the confirmation, **Expedite deletion
     queue**.
   - **CLI:** `docker exec ente-janitor expedite-all`
3. **Watch it drain:** museum purges ≤5000 objects per 8-minute run:
   ```bash
   docker logs -f ente-museum 2>&1 | grep -i 'cleanup\|deleted'
   watch -n 60 du -sh ${STORAGE_PATH}/ente-minio
   ```
4. Done when the panel shows ~0 pending and `du` matches Ente's reported usage
   (plus thumbnails/overhead).

## Monitoring

- **Gauge:** the janitor logs pending count/bytes every run and (if
  `JANITOR_HEALTHCHECK_URL` is set) pushes `pending=<n> bytes=<n>` to an
  Uptime Kuma push monitor — create one ("ente-janitor", expected daily) and
  paste its URL into `services/ente-janitor/.env`. A growing pending gauge =
  churn arriving faster than the window drains it.
- **Panel:** the admin panel shows pending objects/bytes/oldest-age live.
- **Ad-hoc SQL** (matches what janitor/panel run):
  ```sql
  SELECT count(*), pg_size_pretty(coalesce(sum(ok.size),0))
  FROM queue q LEFT JOIN object_keys ok ON ok.object_key = q.item
  WHERE q.queue_name = 'deleteObject' AND q.is_deleted = false;
  ```
- **Disk:** `/storage` filling breaks Ente uploads (backpressure) but not the
  host — root FS is separate, and mount points fail closed.

## Sizing the exposure (8 TB host)

Worst-case purge-pending pool ≈ N days × sustained delete rate. With N=2, an
adversary would need ~4 TB/day of *upload* churn to threaten the host —
residential uplinks can't physically deliver that. Organic member churn is
noise at this window. Per-user quotas (`ente admin update-subscription`;
self-hosted free-plan default is 10 GiB) additionally cap live+trash per
member and per-cycle churn.

## What we deliberately did NOT do

- **No patched museum / no config fork** — the delay is hard-coded upstream;
  we only backdate queue timestamps via Ente's own documented workaround, and
  museum's cleanup does all actual deletion (S3 + `object_keys` bookkeeping).
  Nothing here breaks on Ente upgrades short of a queue-schema change.
- **No hourly full flush** — that would silently delete the recovery buffer
  policy-wide. The window is a deliberate, documented number (N), and full
  flushes are explicit admin actions.
- **No direct MinIO deletion** — an external job deleting objects behind
  museum's back would desync `object_keys` and the queue.

Upstream refs: hard-coded delay `server/pkg/repo/queue.go`
(`DeleteObjectQueue: 45 * 24 * 60`); sanctioned workaround in
[Ente's self-hosting troubleshooting docs](https://ente.com/help/self-hosting/troubleshooting/misc).
