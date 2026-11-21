# Zero-downtime int4 -> bigint primary key migration: candidate approaches

Problem: `sensor_readings.id` is an `int4` (integer) primary key approaching the
2,147,483,647 overflow ceiling. The next insert past it fails and ingestion
stops fleet-wide. The naive fix — `ALTER COLUMN id TYPE bigint` — rewrites the
whole table under `ACCESS EXCLUSIVE` (hours of downtime). Below are the
zero-downtime candidate approaches. The agent proposes; a human chooses; each is
tested on its own ephemeral service with real evidence.

## A — Raw-SQL expand/contract on the PK

Hand-authored shadow column + backfill + view/trigger dual-read, committed as
raw SQL (e.g. a Prisma raw migration). Steps, each online:
1. Add `id_big bigint` (nullable, no rewrite).
2. Backfill in batches (`UPDATE ... WHERE id BETWEEN ...`), throttled.
3. Trigger keeps `id_big` in sync for new/updated rows during backfill.
4. Build a unique index on `id_big` `CONCURRENTLY`.
5. Promote `id_big` to the primary key, repoint foreign keys, drop the old `id`.

Hardest case because `id` is the PK referenced by FKs. Measure backfill
duration at scale, lock behavior at the swap, and impact on live ingest.

## B — New bigint column, dual-write, swap PK

Similar to A but framed around dual-write at the application layer: the app
writes both `id` and `id_big` during the transition. Batch backfill the old
rows, build the unique index `CONCURRENTLY`, swap the PK, repoint FKs. Each step
is online; good fit for a never-stop ingest pipeline. The swap is the only
brief lock.

## C — Negative-range sequence stopgap

Reset the sequence into the NEGATIVE int4 range (down to -2,147,483,648) to buy
roughly another 2.1 billion ids of runway WITHOUT changing the column type.
This is a STOPGAP, not a fix: it defers the overflow so a proper bigint
migration (A, B, or D) can run in the background. int4 still can't exceed its
range; you have only bought time. Never present this as the final solution.

## D — Convert to a TimescaleDB hypertable (Tiger-native)

Rather than widen the PK on a monolithic table, migrate the hot table into a
hypertable partitioned on the time dimension (`recorded_at`). This reframes the
problem instead of patching the column.

Key design consequence: a hypertable's unique/primary key MUST include the
partitioning column. So the plain `int4` monotonic PK is replaced by a `bigint`
id combined with `recorded_at` (a composite key), or the id is de-emphasized in
favor of time-based access. This is a bigger schema/access-model change than
A/B/C, but it unlocks Tiger-native compression, retention, and continuous
aggregates. Measure: in-place `create_hypertable` vs. blue-green copy into a new
hypertable, lock/rewrite behavior, backfill/copy duration, ingest latency during
migration, and chunk configuration.

## How to choose

There is no single "best" — the four are tested in parallel on identical
evaluation (max lock level + hold time, full rewrite yes/no, backfill duration,
ingest p50/p95 during expand, WAL/storage delta, correctness). The human
compares the evidence and decides; only the chosen approach proceeds to the
gated production path.
