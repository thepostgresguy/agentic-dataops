---
marp: true
theme: default
paginate: true
size: 16:9
title: "Agents write migrations. Production needs guardrails."
description: "SRE Day NY 2026: an agent-assisted PostgreSQL workflow on Tiger Cloud"
style: |
  section {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #0b1020;
    color: #e6e9f0;
    padding: 56px 72px;
  }
  h1, h2 { color: #2dd4bf; }
  h1 { font-size: 1.9em; }
  h2 { font-size: 1.4em; }
  strong { color: #f59e0b; }
  em { color: #9ec5ff; }
  a { color: #9ec5ff; }
  code { background: #1d2944; color: #9ec5ff; border-radius: 4px; }
  pre { background: #131a2e; border: 1px solid #22304f; border-radius: 8px; }
  table { font-size: 0.72em; }
  th { background: #1d2944; color: #2dd4bf; }
  td { background: #131a2e; }
  blockquote { border-left: 4px solid #2dd4bf; color: #8b96ad; }
  section.lead { text-align: center; justify-content: center; }
  section.lead h1 { font-size: 2.3em; }
  section.demo { background: #1a1030; }
  section.demo h2 { color: #f59e0b; }
  footer { color: #5c6680; }
footer: "SRE Day NY 2026 · agent-assisted PostgreSQL delivery"
---

<!-- _class: lead -->
<!-- _paginate: false -->

# Agents write migrations.
# Production needs guardrails.

An agent-assisted PostgreSQL workflow on **Tiger Cloud**

SRE Day NY 2026

<!--
Opening. One line: AI agents can already write the SQL. The hard part is letting
them near production safely. What follows is a working blueprint, live.
-->

---

## The promise

> AI agents can write migrations, but production changes need guardrails.

What you will see, running for real:

- An **isolated dev service** provisioned with the Tiger CLI
- **Versioned migrations**, reviewed by an agent
- **Correctness and performance** tested before anyone approves
- **Scoped access**, automated checks, **lock and rewrite detection**
- **Human-approved** deployment, monitoring and rollback criteria

You leave with a blueprint to **speed up database delivery without giving an
agent unchecked authority over production.**

---

## The problem: a counter about to run out

An IoT fleet streams sensor readings into one hot table.

| | |
|---|---|
| Table | `sensor_readings` |
| Primary key | `id integer` (**int4**) |
| Ceiling | **2,147,483,647** |
| Size | ~2.1 billion rows, ~2 TB |
| What happens at the ceiling | the next `INSERT` fails, **ingestion stops fleet-wide** |

The fix sounds trivial: make it a `bigint`.

<!--
Real, famous production hazard. Everyone in the room has either hit it or fears
it. Set up the tension: the obvious fix is the dangerous one.
-->

---

## The obvious fix is the dangerous one

```sql
ALTER TABLE sensor_readings ALTER COLUMN id TYPE bigint;
```

- Takes an **`ACCESS EXCLUSIVE`** lock: no reads, no writes
- **Rewrites the entire table** and every dependent index and foreign key
- On ~2 TB that is **hours of downtime** and dropped telemetry

An ORM will generate exactly this from a one-word model change (`Int` → `BigInt`).

> An agent that writes this migration, confidently, is the failure mode.

---

## So what do we let the agent do?

|  | Agent | Human |
|---|---|---|
| Brainstorm several approaches | ✅ | |
| Spin up isolated test databases | ✅ | |
| Run the same evaluation on each | ✅ | |
| Explain hazards with evidence | ✅ | |
| Choose the approach | | ✅ |
| Approve production deployment | | ✅ |

**The agent is a fast, parallel experimenter. It never gets the final word.**

---

## The pattern

```
 problem  ──►  agent proposes  ──►  tested in isolation  ──►  human decides  ──►  gated prod
 (human)       up to 4 options      real evidence             picks one            approval
```

Five rules that hold the whole thing together:

1. **Everything is code.** No manual steps, no clicking through consoles.
2. **Isolation first.** Experiments run on ephemeral databases, never prod.
3. **Evidence over opinion.** Lock modes and rewrites are measured, not guessed.
4. **Least privilege.** The agent holds no production credentials.
5. **Humans own the irreversible.** Deploys are gated and approved.

---

## Architecture: two compute planes, kept apart

| Plane | Runs | Technology |
|---|---|---|
| **Pipeline** | GitHub Actions jobs | AWS CodeBuild-hosted runner, IAM role auth |
| **AI agent** | The reasoning loop | Amazon Bedrock **AgentCore** Runtime (Strands, Nova Pro) |
| **Databases** | Permanent + ephemeral | **Tiger Cloud** (Postgres + TimescaleDB) |
| **Migrations** | Schema changes | **Liquibase** (the ORM only queries) |
| **Infrastructure** | Everything above | OpenTofu, `us-east-1` |
| **Secrets** | Credentials | AWS Secrets Manager, **none in GitHub** |

The workflow *invokes* the agent. The agent never runs on the runner.

<!--
Keep this brief. The audience came for the workflow, not the IAM policy. The
AWS-native stack is the foundation, not the headline.
-->

---

## Where Tiger Cloud fits

- **Tiger CLI** creates an isolated service per test run, then deletes it
- **Ephemeral services** are the agent's scratch space: safe to break
- **Permanent services** are private (VPC-peered): the **app database** and the **RAG store**
- **TimescaleDB** is built in, which makes a Tiger-native option possible:
  turn the hot table into a **hypertable**

```bash
tiger service create --name mt-<run-id> --with-password
tiger db uri --service-id <id> --password-storage none
tiger service delete <id>          # always, even when the run fails
```

---

## The flow, end to end

1. **Author.** A developer adds a Liquibase changeset in a PR
2. **Review.** Guardrails run, the agent returns a verdict and up to 4 options. *No database touched.*
3. **Test.** A human pastes one option. It runs on an ephemeral Tiger service.
4. **Decide and teach.** The human records the decision. The agent learns from it.
5. **Ship.** Nothing deploys from a PR. Deployment is a separate, gated step.

Each step is a **GitHub Actions workflow**. Let's walk them.

---

## 1 · Author: migrations are immutable files

```sql
--liquibase formatted sql

--changeset agentic-dataops:002_sensor_readings_id_bigint
ALTER TABLE "sensor_readings" ALTER COLUMN "id" TYPE BIGINT;
--rollback ALTER TABLE "sensor_readings" ALTER COLUMN "id" TYPE INTEGER;
```

- `infra/db/app/changesets/NNN_<name>.sql`: the **number is the apply order**
- **Never edit** a changeset that is on `main`. Add a new one.
- Every changeset has a **`--rollback`**
- The ORM model is updated in the same PR, so the client matches the database

---

## What the ORM produces

Change one word in the model:

```diff
 model SensorReading {
-  id  Int     @id @default(autoincrement())
+  id  BigInt  @id @default(autoincrement())
```

and the migration it generates is, in essence, the one-statement table rewrite:

```sql
ALTER TABLE "sensor_readings" ALTER COLUMN "id" SET DATA TYPE BIGINT;
```

Same hazard, zero warning. The ORM is great at queries. **It does not know your
table has two terabytes in it.**

<!--
Teaching moment. In this repo Liquibase owns migrations and Prisma is the query
client only; this shows what a naive ORM-owned flow would have shipped.
-->

---

## Guardrail 1 · Immutable, tagged history

How the database history stays trustworthy:

| Mechanism | What it gives you |
|---|---|
| Changesets are **new files**, never edits | History is the audit trail |
| Liquibase **checksums** every applied changeset | An edited, already-applied one **fails at deploy** |
| `includeAll` loads files alphabetically | The **number is the apply order** |
| Every `update` **tags the database** with the git SHA | Roll back **by tag** |

The rest is convention and review: naming, ordering and a `--rollback` per
changeset.

---

## 2 · Review: the agent reads the SQL

`migration-review` takes the changesets a PR **adds** and asks the consultant.

- **Tool-less on purpose.** It touches *no database*.
- **Grounded** in a knowledge base (RAG) of playbooks and past decisions
- Returns:
  1. **Verdict**: safe, or unsafe
  2. **Hazard assessment** per statement: lock, rewrite, blast radius
  3. **Up to 4 candidate approaches**, never padded
  4. **Recommendation**, which a human may overrule
- Posted as a **PR comment**

---

## The four candidates (we keep all four)

| | Approach | Character |
|---|---|---|
| **A** | Expand/contract: shadow column, backfill, views and triggers | Hardest, fully online |
| **B** | New `bigint` column, dual-write, swap the primary key | Multi-step, each step online |
| **C** | Reset the sequence into the negative int4 range | **Stopgap**, buys runway |
| **D** | Convert to a **TimescaleDB hypertable** on `recorded_at` | Tiger-native, changes the access model |

Choosing among them is **the demo**. No candidate is crowned ahead of time.

<!--
D reframes the problem instead of patching the column. Its cost: a hypertable
primary key must include the partitioning column.
-->

---

<!-- _class: demo -->

## 3 · Test: an ephemeral database per candidate

`migration-test`, with the option's SQL pasted in:

1. **Create** an ephemeral Tiger service, wait until it accepts connections
2. **Check out `main`**, the committed source of truth
3. **`liquibase update`** builds the schema from `main`'s changesets
4. **Apply the option SQL**, capturing evidence
5. **Agent analyzes** the evidence, read-only, on the same ephemeral
6. **Destroy** the ephemeral service. Always.

The app database is **never read or touched**.

---

## Evidence, not opinion

What each run measures:

| Signal | Why it matters |
|---|---|
| **Lock modes held** | Did it take `ACCESS EXCLUSIVE`? |
| **Full-table rewrite** (yes/no) | The hours-of-downtime question |
| **Elapsed time** | Relative cost of each step |
| **Errors** | e.g. `NOT NULL` with no default on a populated table |

> **Honest caveat:** the ephemeral is schema-only, so timings reflect empty
> tables. The lock *type* and rewrite *yes/no* are real. Scale is a seeding
> decision: ~1M rows live, one recorded run at billion-row scale.

---

## The agent as an agentic workload

In `migration-test` the consultant **chooses its own steps**:

```
reason  ──►  call a tool  ──►  observe  ──►  repeat   (bounded)
```

- Tools: `describe_table` and `run_readonly_query`, on the ephemeral clone
- It writes its own SQL: catalog lookups, sequence state, FK checks
- Every step is recorded in the run's **Agent trace**

Agents bring **non-deterministic, bursty, machine-written queries**. The
database side needs guardrails built for that.

---

## Guardrails on the agent itself

| Control | Setting |
|---|---|
| Dedicated role `agent_ro` | `SELECT` only |
| Transaction mode | `default_transaction_read_only`, `READ ONLY` per call |
| Statement timeout | **5 s** |
| Result size | **50 rows** max |
| Statements per call | **One** |
| Call budget | **12 tool calls** |
| Where | Ephemeral service only, **never prod** |

The write guardrail is **proven before use**: the workflow tries a `CREATE TABLE`
as `agent_ro` and aborts if it succeeds.

---

## Scoped access: who can touch what

| Actor | Can | Cannot |
|---|---|---|
| **Agent** | Read the SQL, read-only tools on an ephemeral | Hold prod credentials, apply anything, deploy |
| **Pipeline runner** | Create and delete ephemerals, run workflows | Auto-deploy to prod |
| **PR author** | Propose a changeset | Edit history on `main` |
| **Human reviewer** | Pick an option, record the decision | |
| **Prod deploy** | Manual workflow today; human-approved GitHub Environment for the dedicated prod service | Run from a PR |

No AWS keys in GitHub. Secrets live in **AWS Secrets Manager**, read at run time
through IAM roles.

---

## 4 · Decide, then teach the agent

The human records the decision as a file:

`agent/knowledge/decisions/<date>-<slug>.md`

- SQL reviewed, verdict, **chosen approach**, rationale
- Commit it, run **`rag-ingest`** (incremental, content-hashed)
- Future reviews **retrieve your past decisions**

The agent recommends. The human decides. **The agent learns from the decision.**

---

## 5 · Production: gated, tagged, reversible

- **Nothing deploys from a PR.** Deploy is a separate, manually dispatched
  workflow (the approval gate on a dedicated prod service comes with that service)
- Images are tagged with the **git SHA**, in an *immutable* registry
- `liquibase update` **tags the database** with the same SHA
- Rollback is **by tag** (preferred) or by count, from a workflow
- `run_migrations` is an explicit choice, so a code-only redeploy cannot
  accidentally ship a hazardous changeset

> Building an image is not deploying it. That separation is the point.

---

## Monitoring and rollback criteria

**Designed, with the pieces started. Honest status:**

| Piece | Status |
|---|---|
| Rollback by DB tag | ✅ Available (`app-migrate rollback`) |
| Rollback criteria script (lock waits, errors over a window) | 🟡 Written, not yet wired into a workflow |
| Datadog dashboards, monitors, phase events | ⬜ Strategy still to be designed |

The target: post-deploy signals (lock waits, error rate, ingest p95) **trip an
automated rollback**, with no human judgment needed in the moment.

---

<!-- _class: demo -->

## Live demo: run of show

1. **Show the hazard.** `/stats` gauge on the app, int4 ceiling in sight
2. **Open the PR** with changeset `002`
3. **Read the review** comment: verdict **UNSAFE**, up to 4 approaches
4. **Pick an option.** Paste its SQL into `migration-test`
5. **Watch the ephemeral** appear in Tiger, then the evidence and agent trace
6. **Read the report.** Lock modes, rewrite yes/no, agent findings
7. **Record the decision.** Commit it, run `rag-ingest`
8. **Deploy** through the gated workflow

<!--
Pre-flight (do before going on stage): SSH key loaded, runner online, AgentCore
runtime resolves, Tiger credentials secret populated, previous image deployed.
Have a recorded run ready as a fallback.
-->

---

## What went wrong building this (and what it taught us)

| We hit | Lesson |
|---|---|
| A new image, but the **same page** | Building is not deploying. Make the rollout a visible step |
| `Connection refused` right after create | **Created is not ready.** Wait for connections |
| `no password supplied` | Tiger shows the password **once, at create time**. Capture it then |
| A tag collision on re-deploy | Immutable tags are a feature. Move forward with a new commit |
| A `bigint` change broke the TypeScript build | Schema types flow into app code. CI catches it |

Real failures make the guardrails credible.

---

## The blueprint

1. **Isolate.** Give every experiment its own ephemeral database
2. **Constrain.** Least-privilege roles, read-only tools, timeouts, budgets
3. **Measure.** Detect locks and rewrites with evidence, not intuition
4. **Gate.** Humans approve anything irreversible
5. **Make it reversible.** Immutable history, tagged deploys, rollback criteria
6. **Close the loop.** Record decisions so the agent improves

> Accelerate the work. Keep the authority.

---

<!-- _class: lead -->
<!-- _paginate: false -->

# Questions?

**github.com/thepostgresguy/agentic-dataops**

Everything shown is code in this repository:
workflows, changesets, guardrails, and the agent.

<!--
Backup material: the four candidate migrations in detail, the evaluation matrix
(ingest latency p50/p95, WAL delta, correctness diff), and the hypertable
trade-offs.
-->
