# Zero-downtime migration principles

General patterns for changing a schema without taking the application down.
These underpin the specific int4->bigint playbooks.

## Expand / contract (the core pattern)

Never change a column in place on a hot table. Instead:
1. EXPAND — add the new shape alongside the old (new column/table/index),
   backfill it, and keep both in sync (triggers or dual-write).
2. MIGRATE READS/WRITES — move the application to the new shape gradually; both
   old and new can serve traffic simultaneously during the transition.
3. CONTRACT — once nothing reads the old shape, drop it.

Each step is individually online and reversible. The migration is a sequence of
safe steps, not one blocking statement.

## Backfill in throttled batches

Rewriting billions of rows in one `UPDATE` holds locks and bloats WAL. Instead,
backfill in bounded batches (by id or time range), with a short pause between
batches so autovacuum and replication keep up and live traffic is not starved.
Make the backfill resumable and idempotent.

## Build indexes CONCURRENTLY

`CREATE INDEX CONCURRENTLY` does not take `ACCESS EXCLUSIVE` and does not block
writes. It is slower and cannot run inside a transaction block, and it can leave
an INVALID index if it fails (drop and retry). Always prefer it on hot tables.

## Split constraint validation

Add constraints `NOT VALID` first (cheap, metadata-only), then
`VALIDATE CONSTRAINT` separately — the validation scan takes a weaker lock than
adding an already-valid constraint, so writes are not blocked for the whole
scan.

## Dual-read / dual-shape during transition

A view/trigger layer (or an application connection that selects the old-shape or
new-shape view) lets old and new application versions run against the SAME
physical table at once. This is what makes "live traffic during migration"
real: flip instances between shapes without downtime.

## Always have a rollback

Every migration step should have a defined reverse. Keep migrations small and
individually reversible; prefer additive changes that can be rolled back by
dropping the new object, over destructive in-place changes that cannot.

## Measure before you choose

Correctness alone is not enough. For each candidate measure: maximum lock level
and hold time, whether a full-table rewrite occurs, backfill duration, ingest
and read latency (p50/p95) during the change, and WAL/storage delta. Decide from
evidence, not intuition.
