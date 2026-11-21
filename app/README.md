# app — IoT telemetry demo (TypeScript + Fastify + Prisma)

The sample app the migration demo operates on. A fleet of IoT devices streams
sensor readings into Postgres (Tiger Cloud). The hazard is
**`sensor_readings.id`**: an `int4` primary key about to overflow at ~2.1B rows,
which the workshop migrates to `bigint` with zero downtime.

It runs on ECS Fargate behind an ALB at `overflow.thepostgresguy.com`.

## What's here

- `src/server.ts` — the Fastify web server (what ECS and the ALB run).
- `prisma/schema.prisma` — the Prisma **query client** models: `devices`
  (bigint id), `sensor_readings`, `device_usage_charges` (money is
  `NUMERIC(15,2)`). It is kept in sync with the Liquibase changesets by hand.
- `src/db.ts` — Prisma client factory and `search_path` helper.
  `APP_SCHEMA_VERSION` flips the app between OLD and NEW table shapes during a
  zero-downtime migration (one env change, same physical database).
- `src/ingest.ts` — ingest/read loop that proves ingestion never stops during a
  migration. Low, configurable rate.
- `src/seed.ts` — parameterized seed harness. The same code does the **1M live**
  boundary (with `SEED_SEQ_START` resetting the id sequence near the
  2,147,483,647 ceiling so overflow is imminent) and the one-off **1B recorded**
  run. Never seed billions on the parallel bake-off.
- `src/dd.ts` — Datadog hooks, **inert** (`DD_ENABLED=false`); monitoring is a
  deferred phase.
- `Dockerfile` — the container image (Node 22, non-root, runs `dist/server.js`).

## Endpoints

| Route | Returns |
|---|---|
| `GET /` | A generic branded landing page (no database access) |
| `GET /health` | Liveness and readiness. Runs `SELECT 1`, returns 503 if the DB is down. The ALB health check uses it |
| `GET /stats` | The overflow gauge: current `sensor_readings.id` (max row and sequence value) against the int4 ceiling |
| `GET /devices` | Devices, paginated (`limit`, `offset`) |
| `GET /readings/recent` | Most recent sensor readings (`limit`) |

`BigInt` ids are returned as strings because `BigInt` is not JSON-serializable.

## Connection

The app reads a single `DATABASE_URL`. In the pipeline it comes from AWS
Secrets Manager (`agentic-dataops/app/database-url`) and is injected into the
ECS task. To run elsewhere, copy `.env.example` → `.env` and paste a Tiger DSN.
**Never localhost; never commit a real `.env`.** The app database is private, so
it is only reachable from inside the VPC.

## Schema changes

**Liquibase owns migrations; Prisma is the query client only.**

- Changesets live in [`infra/db/app/changesets/`](../infra/db/README.md) and are
  applied in CI (`app-migrate`, `deploy`) with `liquibase update`.
- When you add a changeset, update `prisma/schema.prisma` in the same PR so the
  generated client types match the database.
- Never run `prisma migrate` or `prisma db push`. There is no
  `app/prisma/migrations/`.
- The review flow (`migration-review`, `migration-test`) is described in the
  [workflows README](../.github/workflows/README.md).

> `schema.prisma` already shows `SensorReading.id` as `BigInt` (changeset `002`).
> The live app database stays `int4` until that changeset is applied, so
> `/stats` keeps reporting the int4 ceiling. Hypertables are not a Prisma
> concept: `create_hypertable(...)` is plain SQL in a changeset, and a
> hypertable primary key must include the `recorded_at` partitioning column.

## Build and verify (offline)

```bash
npm install
npm run prisma:validate     # validates schema.prisma, no DB
npm run prisma:generate     # generates the client, no DB
npm run typecheck           # tsc --noEmit
npm run build               # tsc, same as the Docker build
```

Because the generated client types follow `schema.prisma`, changing a column
type there can break the TypeScript build. For example `id` moving from `Int` to
`BigInt` changes `number` to `bigint` in `src/server.ts`.

Running against a database (`npm run seed`, `npm run ingest`) needs a real
`DATABASE_URL`.

## Deploy

1. `app-image` builds and pushes `agentic-dataops/app:<git-sha>` to ECR on every
   push to `main` that touches `app/**`. It does **not** deploy.
2. `deploy` (manual) rebuilds, runs `tofu apply` with that SHA, optionally runs
   Liquibase, and forces a new ECS deployment.

ECR tags are immutable. Re-running `deploy` on a commit whose image already
exists fails at the push, so make a new commit first.
