# scripts

Scripts the workflows call. They are written for CI (non-interactive, quoted
values, secrets never printed) and are **not meant to be run by hand**.

## Used by workflows

| Script | Used by | What it does |
|---|---|---|
| `liquibase_app.sh <command> [arg]` | `app-migrate`, `deploy`, `migration-test` | Runs Liquibase in a container against the app DB. Commands: `update`, `update-sql`, `status`, `history`, `validate`, `baseline-sync`, `rollback <tag>`, `rollback-count <n>`, `release-locks`. The changelog is mounted from git |
| `provision_dev_service.sh <name> [region]` | `migration-test` | Creates an ephemeral Tiger service, captures its password at create time, waits until it accepts connections, and emits `service_id` and `dsn` |
| `teardown_dev_service.sh <service_id>` | `migration-test` | Deletes the ephemeral service. Safe to call twice |
| `migration_dryrun.sh <dsn> <sql> <evidence>` | `migration-test` | Applies SQL to an **ephemeral** service and records lock modes, whether tables were rewritten, elapsed time and any error. Never point it at the app DB |
| `extract_agent_text.py <response> [--trace-out f]` | `migration-review`, `migration-test` | Turns the AgentCore streaming response into plain text, with the agent's steps split out as a trace |
| `lib.sh` | the Tiger scripts | Shared helpers: `log`, `ok`, `fail`, `psql_do`, `tiger_login_from_secret` |

### Optional overrides for `liquibase_app.sh`

By default it migrates the app DB from the secret
`agentic-dataops/app/database-url` using `infra/db/app` in this checkout.
`migration-test` overrides both:

| Variable | Effect |
|---|---|
| `LIQUIBASE_TARGET_DSN` | Migrate this `postgresql://` DSN (an ephemeral service) instead of the app secret |
| `LIQUIBASE_CHANGELOG_DIR` | Use this directory (for example a checkout of `main`) instead of `infra/db/app` |
| `LIQUIBASE_TAG` | Tag applied after `update` (default: the current git SHA) |

## Guardrail scripts not currently wired into a workflow

These exist as coded guardrails, but no workflow in `.github/workflows/`
calls them today.

| Script | Purpose |
|---|---|
| `detect_lock_rewrite.sh` | Static check that fails on DDL that takes `ACCESS EXCLUSIVE` and rewrites a table (for example `ALTER COLUMN ... TYPE` on `sensor_readings.id`). See `migrations/unsafe-examples/` |
| `analyze_gate.sh` | Runs `iqtoolkit-analyzer` against a database and fails above a slow-query or severity threshold |
| `rollback_criteria.sh` | Polls lock waits and errors for a window after a migration and exits non-zero to trigger rollback |
| `schema_signature.sql` | A stable schema signature for comparing two databases |

## Conventions

- `set -euo pipefail`, quote every value, treat external output as untrusted.
- Authentication comes from the runner's IAM role plus Secrets Manager. No
  credentials are stored in GitHub.
- Provisioned services are always torn down by an `if: always()` step.
