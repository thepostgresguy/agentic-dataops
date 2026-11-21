# infra/db — Liquibase changelogs

**Liquibase owns every schema change** for both databases. Prisma is only the
app's query client and never runs migrations.

| Directory | Database | Applied by |
|---|---|---|
| [`app/`](app/) | App DB (`agentic-dataops-app`) | `app-migrate`, `deploy` (via `scripts/liquibase_app.sh`) |
| [`rag/`](rag/) | RAG store (`agentic-dataops-rag`) | `rag-migrate` |

Each directory has a `changelog.xml` that uses `includeAll` over `changesets/`,
so files load alphabetically and **the number is the apply order**.

## Rules (conventions, not checked on PRs)

No PR check enforces these. Liquibase itself only catches an edit to an already
applied changeset (checksum failure at deploy time); the naming, ordering and
`--rollback` rules below are on you and your reviewers.

- **Immutable.** Never edit, delete or rename a changeset that exists on `main`.
  Every change is a new file. Liquibase fails an edited, already applied
  changeset on its checksum at deploy time.
- **Named `NNN_<name>.sql`.** Three digits, then lowercase letters, digits and
  underscores. Numbered above the highest existing one, numbers unique.
- **Liquibase formatted SQL.** First line `--liquibase formatted sql`, a
  `--changeset author:id` line per change, and a `--rollback` for each one.
- Files a PR itself adds may still change within that PR (they were never
  applied).

## Add an app changeset

1. Create `app/changesets/NNN_<name>.sql`:

   ```sql
   --liquibase formatted sql

   --changeset agentic-dataops:003_example labels:example
   --comment: what this does and why
   ALTER TABLE "devices" ADD COLUMN "firmware" TEXT;
   --rollback ALTER TABLE "devices" DROP COLUMN "firmware";
   ```

2. Update `app/prisma/schema.prisma` in the same PR so the generated client
   matches.
3. Open a PR. `migration-review` sends the new changeset to the AI consultant.

Never run `prisma migrate` or `prisma db push`, and never apply changesets by
hand. Workflows run `liquibase update`, which also tags the database so you can
roll back by tag (preferred) or by count.

## App changesets today

| File | What it does |
|---|---|
| `001_baseline.sql` | Baseline of the existing schema (`devices`, `sensor_readings` with the `int4` id hazard, `device_usage_charges`). On the existing app DB it is marked as run with `app-migrate baseline-sync`, not executed. On a fresh database `update` creates it |
| `002_sensor_readings_id_bigint.sql` | The **naive** `ALTER COLUMN id TYPE bigint`. It is the hazard the review flow is meant to flag, not a change to ship as is |

## RAG changesets

`rag/changesets/001`–`006` create the extensions, the `rag_documents` table,
storage settings, indexes, an `updated_at` trigger and a `content_hash` column.
`rag/` also holds the Liquibase runtime image (`Dockerfile`, `entrypoint.sh`,
`liquibase.defaults.properties`). The changelog is **mounted at run time**, not
baked in, so adding a changeset needs no image rebuild.

`infra/sql/rag_schema.sql` is the earlier hand-written DDL for the RAG store.
The changesets here are authoritative.
