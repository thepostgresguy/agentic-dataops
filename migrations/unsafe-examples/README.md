# Unsafe migration examples (for guardrail demonstration)

These files are **not** part of the applied migration set. Schema changes are
Liquibase changesets under [`infra/db/app/changesets/`](../../infra/db/README.md);
this folder only holds deliberately unsafe SQL for the lock/rewrite guardrail
(`scripts/detect_lock_rewrite.sh`) to catch.

- `0099_unsafe_type_change.sql` — the naive migration an ORM autogenerates from
  an `Int → BigInt` model change on `sensor_readings.id` (the IoT primary-key
  overflow scenario). On a 2.1-billion-row, multi-terabyte (~2 TB) table this
  raw `ALTER TABLE ... ALTER COLUMN id TYPE bigint` forces a full-table rewrite
  while holding an `ACCESS EXCLUSIVE` lock, blocking all reads and writes — and
  halting IoT ingestion — for hours. It also has to rewrite every dependent
  index and foreign key. This is the "do NOT do this" centerpiece: a human
  reviews the plan and chooses among the candidate approaches (A–D), which are
  the zero-downtime fixes.

The check is static: it inspects the SQL text and fails if any operation would
take a table-level `ACCESS EXCLUSIVE` lock on a hot/PK column or trigger a
full-table rewrite (for example `ALTER COLUMN ... TYPE` on `sensor_readings` /
`id`). It needs no database connection.

> Status: `detect_lock_rewrite.sh` is not currently called by a workflow. The
> live review path is `migration-review` (AI consultant) and
> `migration-test` (real lock/rewrite evidence on an ephemeral database). Note
> that `infra/db/app/changesets/002_sensor_readings_id_bigint.sql` contains the
> same naive statement on purpose, as the subject of that review.
