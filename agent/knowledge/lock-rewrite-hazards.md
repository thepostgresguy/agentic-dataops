# Lock and rewrite hazards in PostgreSQL schema migrations

## ACCESS EXCLUSIVE and full-table rewrites

Some `ALTER TABLE` operations take an `ACCESS EXCLUSIVE` lock — the strongest
lock in PostgreSQL. It blocks all reads AND writes on the table for the whole
duration. On a large, hot table this means total downtime: queries queue,
ingestion stalls, and the application effectively halts for that table.

Worse, some operations also force a **full-table rewrite**: PostgreSQL rewrites
every row into a new on-disk relation while holding `ACCESS EXCLUSIVE`. On a
2.1-billion-row, multi-terabyte table this can take hours. Dependent indexes and
foreign keys are rewritten too, multiplying the cost.

## The canonical hazard: ALTER COLUMN ... TYPE

The most dangerous common migration is a column type change:

    ALTER TABLE sensor_readings ALTER COLUMN id TYPE bigint;

On the primary key of a huge table this is catastrophic: a full-table rewrite
under `ACCESS EXCLUSIVE`, rewriting the PK index and every dependent FK/index.
This is exactly the migration an ORM like Prisma autogenerates when a model's
`Int` field becomes `BigInt`. It must never ship to production as-is.

## Operations that rewrite the table (avoid online)

- `ALTER COLUMN ... TYPE ...` that changes the storage representation
  (int -> bigint, text -> uuid, etc.).
- `ADD COLUMN ... NOT NULL` WITHOUT a constant default (every existing row is
  updated). Note: adding a column with a constant default is cheap in modern
  PostgreSQL (metadata-only), but a volatile default still rewrites.
- Changing a column that forces a rewrite of a dependent index.

## Operations that are safe online (short or no heavy lock)

- `ADD COLUMN` with no default, or with a constant default (metadata-only).
- `CREATE INDEX CONCURRENTLY` (no `ACCESS EXCLUSIVE`; builds without blocking
  writes — but cannot run inside a transaction block).
- `ADD CONSTRAINT ... NOT VALID` then `VALIDATE CONSTRAINT` (splits the lock:
  the validate scan takes a weaker lock).
- Dropping a column (metadata-only; space reclaimed later by vacuum).

## Rule of thumb

Before shipping any migration against a large/hot table, ask: does this take
`ACCESS EXCLUSIVE`, and does it rewrite the table? If yes to either, it needs a
zero-downtime approach (expand/contract, dual-write + swap, or a Tiger-native
reframing), not the naive single statement.
