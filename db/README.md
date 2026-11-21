# db — early reference SQL (not used by the pipeline)

This directory predates the move to Liquibase. **Nothing in
`.github/workflows/` or `scripts/` references it**, so it is not applied by any
workflow.

| Path | What it is |
|---|---|
| `schema/0001_baseline.sql` | An early hand-written baseline of the IoT schema |
| `seed/0001_seed.sql` | Early seed data |
| `tests/0001_add_device_firmware.test.sql` | An example test for a "add firmware column" change |

The source of truth for the schema is the Liquibase changesets in
[`infra/db/app/changesets/`](../infra/db/app/changesets/). See
[`infra/db/README.md`](../infra/db/README.md).
