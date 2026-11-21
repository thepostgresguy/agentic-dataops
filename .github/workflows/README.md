# GitHub Actions workflows

All workflows run on the **AWS-hosted CodeBuild runner**
(`codebuild-agentic-dataops-runner-…`), which is VPC-attached to
`vpc-0123456789abcdef1`. AWS auth is the runner's IAM role — **no AWS keys are
stored in GitHub**, and no Tiger/Datadog secrets live in GitHub either (they are
read at runtime from AWS Secrets Manager). Because the runner is in the VPC, it
can reach the **private** Tiger services (app, RAG) over the VPC peering and
AWS APIs via the VPC interface endpoints.

Two compute planes to keep straight:
- **CodeBuild runner** = the pipeline compute (runs these workflows).
- **AgentCore runtime** = the AI agent; workflows *invoke* it, they don't run it.

Image tags are the **git SHA** (ECR repos are immutable — no `latest`). Workflows
that run a prebuilt image resolve the **newest pushed** tag from ECR, so there is
no hand-edited SHA to keep in sync.

---

## Infrastructure & deploy

### `tofu.yml` — OpenTofu plan/apply (gated)
- **Trigger:** manual (`workflow_dispatch`), input `action` = `plan` (default) or `apply`.
- **Does:** `init` → `fmt -check` → `validate` → `plan`, and `apply -auto-approve`
  **only** when `action=apply`. All runs `-input=false -no-color`. Runs through
  `tofu-with-tiger-creds.sh`, which injects the Tiger provider credentials from
  Secrets Manager (`agentic-dataops/tiger/dev`) so the `timescale` provider can
  authenticate at plan time.
- **Human owns `apply`.** The agent never applies.

### `deploy.yml` — one-button app deploy (manual escape hatch)
- **Trigger:** manual, input `run_migrations` (default true).
- **Does, in order:** build+push the app image to ECR (git SHA) → `tofu apply`
  the runtime (ECS + ALB + ACM) at that tag, through
  `tofu-with-tiger-creds.sh` → `liquibase update` of the app DB
  (`scripts/liquibase_app.sh`, when `run_migrations` is true) → force a new ECS
  deployment. Prints the Cloudflare DNS records (ACM validation + app CNAME) to
  the job summary on first run.
- **`run_migrations`:** set it to `false` for a code-only redeploy. When true it
  applies **every pending changeset** to the app DB, including a hazardous one
  like `002_sensor_readings_id_bigint.sql`.
- **Immutable tags:** the image is tagged with the commit SHA and ECR rejects an
  overwrite. Re-running on a commit that was already built fails at the push, so
  commit something new first.
- **Note:** manual trigger while the fully-automated path is built.

---

## Container images (build → push to ECR)

Each `*-image` workflow auto-triggers on `push` to `main` touching its source
paths, plus manual dispatch. They build and push **only** — deploying is separate.

### `app-image.yml` — app image
- **Builds:** the app container (`app/`), amd64, pushes `agentic-dataops/app:<sha>`.

### `agent-image.yml` — AI agent image
- **Builds:** the consultant agent (`agent/`) as **arm64** (AgentCore requires
  arm64; built via buildx + QEMU on the x86 runner), pushes
  `agentic-dataops/agent:<sha>`. Deploy = set the AgentCore runtime to the tag
  via `tofu apply` (agent.tf auto-resolves the newest image).

### `rag-migrate-image.yml` — Liquibase runtime image
- **Used by:** both `rag-migrate` and the app DB workflows (`app-migrate`,
  `deploy`), which reuse this image and mount their own changelog.
- **Builds:** the Liquibase applier runtime (`infra/db/rag/Dockerfile`:
  Liquibase 5.0 + latest Postgres JDBC driver + AWS CLI + entrypoint), base image
  pulled through the ECR pull-through cache. **The changelog is NOT baked in** —
  it is mounted at run time — so this image only rebuilds when the runtime
  (Dockerfile/entrypoint) changes, not when a changeset is added.

### `rag-ingest-image.yml` — RAG ingestion runtime image
- **Builds:** the ingestion runtime (`agent/ingest.Dockerfile`: Python +
  `ingest.py` + deps). The knowledge corpus is mounted at run time, not baked, so
  adding/editing knowledge needs no image rebuild.

---

## RAG store (the agent's knowledge base)

### `rag-migrate.yml` — apply the RAG schema with Liquibase
- **Trigger:** manual, input `command` = `update` (default) / `status` /
  `validate` / `rollback` (needs `tag`) / `rollback-count` (needs `count`) /
  `release-locks`.
- **Does:** resolves the newest Liquibase image, mounts the **committed** RAG
  changelog (`infra/db/rag/`) into the container, and runs Liquibase against the
  **private** RAG Tiger service (DSN from `agentic-dataops/tiger/rag`). `update`
  also tags the DB with the image SHA (a rollback point after every deploy).
  Runs an offline changelog validate first. Adding a changeset = a commit (no
  image rebuild); `includeAll` picks it up.

### `rag-ingest.yml` — populate the RAG store
- **Trigger:** manual, input `mode` = `incremental` (default, upsert new/changed
  chunks by content hash) / `full` (truncate + reload).
- **Does:** `docker run`s the ingestion image with the knowledge corpus
  (`agent/knowledge/**`, including `decisions/`) mounted; embeds each chunk with
  Amazon Titan Text Embeddings v2 (1024-dim) and upserts into `rag_documents` on
  the private RAG service. This is how human feedback (decision files) gets into
  the agent's knowledge.

### `rag-smoke.yml` — verify RAG retrieval end-to-end
- **Trigger:** manual.
- **Does:** invokes the live AgentCore agent with a known hazardous migration and
  asserts the response is **grounded in the knowledge base** (matches several
  knowledge terms). A coded post-deploy gate — proves the agent actually
  retrieves from `rag_documents`, not just the base model.

---

## App database (schema)

**Liquibase owns the app schema**, exactly as it does for the RAG store.
Prisma is only the app's query client and never migrates anything. Changesets
live in `infra/db/app/changesets/` (see `infra/db/README.md`).

### `app-migrate.yml` — Liquibase against the app DB
- **Trigger:** manual, input `command` (plus `tag` or `count` for rollbacks).
  `deploy` also runs `update` as one of its steps.
- **Commands:** `status`, `history`, `validate`, `update-sql` (all read-only
  previews), `update` (apply pending changesets, then tag the DB with the git
  SHA), `baseline-sync` (one time: mark `001_baseline` as run without executing
  it, because the tables already exist), `rollback` (to a tag, preferred),
  `rollback-count`, `release-locks`.
- **Does:** `scripts/liquibase_app.sh` reads the app DSN from Secrets Manager,
  mounts the committed changelog into the Liquibase image, and runs the command
  against the private app DB over the VPC peering.

---

## Agent-assisted migration review & testing (the workshop core)

These two are the heart of the demo: **review is analysis-only; testing is
separate and explicit.** They work for **any** schema change, not fixed examples.

### `migration-review.yml` — AI review of a schema change (analysis only)
- **Trigger:** `pull_request` (same-repo only) touching `infra/db/app/**` or
  `app/prisma/schema.prisma`, or manual with input `base_ref` (default `main`;
  the dispatched ref is compared against its merge-base with this branch).
- **Does:**
  1. **Collects the SQL under review** from git only: the changesets the PR
     **adds**, in number order. That is exactly what `liquibase update` would run.
  2. Sends it to the AgentCore consultant (RAG-grounded) → **verdict + up to 4
     candidate approaches** (never padded; "N more considered" if there are
     more). Reports to the job summary and, on a PR, as a PR comment.
  - If `schema.prisma` changed without a new changeset it warns, because the
    database would not change.
  - If the PR adds no changeset it reports "No new changeset in this PR".
- **No database is touched** — not the live app DB, not an ephemeral service.
  The only AWS calls are resolving and invoking the AgentCore agent. A PR is the
  test; nothing deploys from it (that is `deploy.yml`).

### `migration-test.yml` — test a candidate approach on an ephemeral database built from `main`
- **Trigger:** manual. Input: `option_sql` (**paste** the candidate approach's
  SQL to test).
- **Flow (7 steps):**
  1. **Create** an ephemeral Tiger service and wait until it accepts connections.
  2. **Check out `main`** — the committed source of truth for the app schema.
  3. **Apply main's Liquibase changesets** (`infra/db/app`) to the ephemeral with
     `liquibase update` (`scripts/liquibase_app.sh`, explicit target DSN).
  4. Liquibase creates and maintains `databasechangelog` /
     `databasechangeloglock` itself, so the ephemeral carries its own migration
     history (nothing is copied from the app DB).
  5. **Apply the pasted option SQL** to the ephemeral, **capturing elapsed time,
     lock modes, full-table-rewrite yes/no, and any error** (via
     `migration_dryrun.sh`, which runs it in one transaction).
  6. **Send the option SQL + results to the AI agent** → analysis for human
     review (into the job summary).
  7. **Drop the ephemeral service** (always).
- **The app database is not touched at all** — nothing is dumped or read from it.

  > NOTE: the ephemeral reflects `main`, not prod's live state: changesets on
  > `main` that are not deployed to prod yet are already applied before the
  > option runs. It is also **structure only** (no table data), so timing
  > reflects empty tables. (Open decision: schema-only vs. also seeding data for
  > realistic big-table timing.)

---

## The learning loop

1. `migration-review` → the agent proposes approaches for a change.
2. `migration-test` → you paste a candidate's SQL and get real lock/rewrite/timing
   evidence from an ephemeral database built from `main`'s changesets.
3. You record the decision — the migration SQL + verdict + chosen approach +
   rationale — as a markdown file under **`agent/knowledge/decisions/`** (see
   `TEMPLATE.md`), and commit it.
4. `rag-ingest` (incremental) embeds it into `rag_documents`.
5. Future `migration-review` runs **retrieve your past decisions**, so the agent's
   recommendations increasingly reflect what your team actually decided — it
   learns from feedback, not just generic docs.

---

## Supporting scripts (`scripts/`)

Invoked by the workflows above (never run by hand). The full catalog is in
[`scripts/README.md`](../../scripts/README.md).
- `liquibase_app.sh` — run Liquibase against the app DB (`app-migrate`,
  `deploy`), or against an ephemeral target with `LIQUIBASE_TARGET_DSN`
  (`migration-test`).
- `provision_dev_service.sh` / `teardown_dev_service.sh` — create/dispose an
  ephemeral Tiger service (Tiger CLI; auth from `agentic-dataops/tiger/dev`).
  Provisioning captures the service password at create time and waits until the
  service accepts connections.
- `migration_dryrun.sh` — apply a migration on an ephemeral service and record
  lock/rewrite/timing evidence.
- `extract_agent_text.py` — extract the agent's text from the AgentCore
  invoke response.
- `infra/tofu/tofu-with-tiger-creds.sh` — wrap `tofu` with the Tiger provider
  credentials from Secrets Manager (used by `tofu.yml` and `deploy.yml`).
