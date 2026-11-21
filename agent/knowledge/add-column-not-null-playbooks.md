# Adding a required (NOT NULL) column to a large table: candidate approaches

Problem: a Prisma model change adds a required field, e.g.
`status String` on `sensor_readings`. Prisma autogenerates:

    ALTER TABLE "sensor_readings" ADD COLUMN "status" TEXT NOT NULL;

On a table that already has rows this is rejected by PostgreSQL ("column ...
contains null values"), so the migration fails at deploy time, mid-release. The
ALTER also requests `ACCESS EXCLUSIVE`, queuing behind long-running queries and
then blocking every read and write behind it. On a ~2.1B-row ingest table that
queue is an outage even when the statement itself is fast.

Always set `lock_timeout` (for example 2-5s) on DDL against a hot table so the
ALTER gives up instead of stalling ingestion, and retry.

## 1 — ADD COLUMN with a constant DEFAULT, then (optionally) drop the default

`ALTER TABLE sensor_readings ADD COLUMN status text NOT NULL DEFAULT 'unknown';`

Metadata-only on PostgreSQL 11+ for a constant default: no table rewrite, brief
`ACCESS EXCLUSIVE` held for milliseconds. Existing rows read the default lazily.
Best when a sensible constant exists. Trade-off: the default value is baked into
history ("unknown" for old rows); a volatile default (`now()`, `random()`)
rewrites the table and does NOT qualify.

## 2 — Nullable column, batched backfill, then enforce NOT NULL safely

1. `ADD COLUMN status text;` (nullable, no default: metadata-only).
2. Deploy the app to write `status` for all new rows.
3. Backfill old rows in small throttled batches (`UPDATE ... WHERE id BETWEEN
   ...`), committing between batches.
4. `ALTER TABLE ... ADD CONSTRAINT status_nn CHECK (status IS NOT NULL) NOT
   VALID;` then `VALIDATE CONSTRAINT status_nn;` (validation takes only a weaker
   `SHARE UPDATE EXCLUSIVE` lock, reads and writes continue).
5. On PostgreSQL 12+, `ALTER COLUMN status SET NOT NULL` then reuses the
   validated CHECK and skips the full scan; drop the CHECK afterwards.

Best when old rows need real computed values. Trade-off: more steps and a
backfill job; the longest-running option, but never blocks ingest.

## 3 — Expand/contract across releases

Release 1 adds the nullable column and the app dual-handles missing values;
release 2 backfills; release 3 enforces NOT NULL and removes the compatibility
code. Safest for application compatibility (old and new app versions run side
by side during rolling deploys), at the cost of three releases.

## 4 — Make the model field optional (no DB constraint)

Declare `status String?` in Prisma. The column stays nullable; the application
enforces presence. No lock risk and the simplest migration, but the database no
longer guarantees the invariant. Acceptable only if a nullable value is
semantically fine.

## What the dry run should show

With approach 1, locks are brief and no relation is rewritten. The naive
single statement fails on a populated table. Any approach that runs a single
`UPDATE` over the whole table is a hazard: it rewrites every row, bloats the
table, and generates large WAL.
