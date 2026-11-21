# agentic-dataops

A demo of an **agent-assisted PostgreSQL migration pipeline**. The agent
proposes, evidence decides, and a human always has the final word.

## Origin

This project started as the live demo for my workshop at SRE Day NY 2026.
After the workshop it became the repository where I show agentic DataOps in
general: agents, ephemeral test databases and CI/CD working together on
database changes. The workshop material (slides and abstract) is kept under
`docs/`, and some of it still refers to the original event.

> **Everything is code. There are no manual steps.** Migrations, testing,
> deployment and teardown all run as GitHub Actions workflows or agents.

## The story

A fleet of IoT devices streams readings into `sensor_readings`, whose `id` is an
`int4` primary key. At ~2.1 billion rows it is about to hit 2,147,483,647 and
halt ingestion fleet-wide. The obvious fix, `ALTER COLUMN id TYPE bigint`,
takes an `ACCESS EXCLUSIVE` lock and rewrites the whole table (hours of
downtime). The demo shows how an AI consultant and ephemeral test databases help
a human pick a safe, zero-downtime approach instead.

The candidate approaches (all kept, choosing among them is the point):

- **A** expand/contract with a shadow column, backfill and views/triggers
- **B** new `bigint` column, dual-write, swap the primary key
- **C** negative-range sequence stopgap (buys time, does not fix)
- **D** convert the table to a TimescaleDB hypertable (Tiger-native)

See [`docs/workshop-abstract.md`](docs/workshop-abstract.md) for the attendee
promise.

## How a change flows

1. **Author.** A developer adds a new Liquibase changeset
   `infra/db/app/changesets/NNN_<name>.sql` and updates
   `app/prisma/schema.prisma` to match, then opens a PR.
2. **Review (`migration-review`).** Sends the new changeset's SQL to the AI
   consultant. Posts a verdict and up to 4 candidate approaches as a PR
   comment. **No database is touched.**
3. **Test (`migration-test`).** A human pastes one option's SQL. The workflow
   builds an **ephemeral** Tiger Cloud database from `main`'s changesets, applies
   the SQL, and records lock modes, rewrite yes/no, timing and errors. The AI
   analyzes the evidence, then the ephemeral is destroyed.
4. **Decide and teach.** The human records the decision under
   `agent/knowledge/decisions/` and runs `rag-ingest`, so future reviews learn
   from it.
5. **Ship.** Nothing deploys from a PR. Deployment is the manual `deploy`
   workflow (`run_migrations` is a choice) or `app-migrate`.

## Architecture

| Plane | Technology | Notes |
|---|---|---|
| Pipeline compute | GitHub Actions on an **AWS CodeBuild** runner | VPC-attached, IAM role auth, no AWS keys in GitHub |
| AI agent | **Amazon Bedrock AgentCore** (Strands, Nova Pro) | Invoked by workflows; never runs on the runner |
| Databases | **Tiger Cloud** (TimescaleDB/Postgres) | Permanent: app + RAG (private, VPC-peered). Ephemeral: per test run |
| Migrations | **Liquibase** | Owns all schema changes for both databases |
| ORM | **Prisma** | Query client only, never runs migrations |
| IaC | **OpenTofu** | `us-east-1` |
| Secrets | **AWS Secrets Manager** | Nothing secret lives in GitHub |

Rules that shape the repo:

- Liquibase changesets are **immutable**: never edit one that is on `main`, add a
  new numbered file instead (Liquibase fails an edited, applied changeset on its
  checksum; nothing else checks this on a PR).
- No local databases, ever. Every DSN points at a Tiger Cloud service.
- The human owns `tofu apply` and production deploys. The agent recommends.

## Repository map

| Path | What it is |
|---|---|
| [`app/`](app/README.md) | The IoT demo app (TypeScript, Fastify, Prisma). Deployed at `overflow.thepostgresguy.com` |
| [`agent/`](agent/README.md) | The AI consultant, its RAG retrieval and the knowledge base |
| [`infra/db/`](infra/db/README.md) | Liquibase changelogs and changesets (app and RAG) |
| [`infra/tofu/`](infra/tofu/README.md) | OpenTofu for the runner, IAM, ECS, ALB, Tiger services, secrets |
| [`.github/workflows/`](.github/workflows/README.md) | Every pipeline, with triggers and inputs |
| [`scripts/`](scripts/README.md) | Scripts the workflows call (never run by hand) |
| [`docs/`](docs/) | Design notes: workshop abstract, AWS agent options, agent how-to |
| [`migrations/unsafe-examples/`](migrations/unsafe-examples/README.md) | Deliberately unsafe SQL for the lock/rewrite guardrail |
| [`db/`](db/README.md) | Early reference SQL, not used by the pipeline |

## Environments

- **Testing and evaluation** are ephemeral Tiger Cloud services, created per run
  and always torn down.
- **App database** (`agentic-dataops-app`) is the workshop's stand-in for
  production. It is private and reachable only from inside the VPC.
- This is the **workshop** repo. The live production repo is separate and is
  never touched from here.

## Getting started

There is nothing to run locally. Everything is a workflow:

| I want to | Run |
|---|---|
| Review a schema change | Open a PR touching `infra/db/app/**` (`migration-review`) |
| Test a candidate approach | Dispatch `migration-test` with the option's SQL |
| Apply changesets to the app DB | Dispatch `app-migrate` (or `deploy` with `run_migrations`) |
| Deploy the app | Dispatch `deploy` |
| Refresh the agent's knowledge | Dispatch `rag-ingest` |

Details and inputs for every workflow are in
[`.github/workflows/README.md`](.github/workflows/README.md).

## Placeholders to replace

This repo is meant to be cloned and run in your own accounts. Values that are
specific to one AWS account, domain or GitHub owner are placeholders or
examples. Replace them before you deploy. Most are defaults in
[`infra/tofu/variables.tf`](infra/tofu/variables.tf), so you can override them
with `-var` or a `*.tfvars` file instead of editing the file.

| Value | Where | Replace with |
|---|---|---|
| `<your-state-bucket>` | `variables.tf` (`state_bucket_name`), `backend.tf` (a literal, no variables allowed) | A globally unique S3 bucket name you own. Use the same name in both files. |
| `123456789012` | `variables.tf` (`tiger_secret_arn`) | Your AWS account ID, or the full ARN of your Tiger credentials secret. |
| `thepostgresguy` | `variables.tf` (`github_owner`) | Your GitHub user or org. |
| `overflow.thepostgresguy.com` | `variables.tf` (`app_domain`) | A domain you control. It is also mentioned in `app/README.md` and in the footer in `app/src/server.ts`. |
| `vpc-0123456789abcdef1` | `variables.tf` (`rag_peer_vpc_id`) | Your VPC ID. |
| `subnet-0123456789abcdef1` to `...4` | `variables.tf` (the ALB and ECS subnet lists) | Your subnet IDs. The public subnets are for the ALB and the private ones are for the tasks. |
| `10.42.0.0/24` | `variables.tf` (`rag_tiger_cidr`) | Any range that doesn't overlap your VPC. |
| `app_image_tag`, `rag_migrate_image_tag` (git SHAs) | `variables.tf` | The SHAs pushed by your own image workflows. The defaults only exist in the original ECR. |
| `ts_project_id`, `ts_access_key`, `ts_secret_key` | Environment (`TF_VAR_...`) | Your Tiger Cloud project ID and API keys. They have no defaults and must never be committed. |

No cloud credentials are stored in GitHub. The workflows run on a CodeBuild
runner inside your VPC and read the Tiger and app database secrets from AWS
Secrets Manager at run time. See the
[workflow README](.github/workflows/README.md) for how the runner works.

## License

See [`LICENSE`](LICENSE).
