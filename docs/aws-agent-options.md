# AWS Agent Options for the `agentic-dataops` Migration Pipeline

Options for building the dev-scoped migration agent (the `kirocrew` role in the
automation charter) on AWS. The agent brainstorms candidate PostgreSQL migration
approaches, drives dataops/devops against **ephemeral Tiger Cloud dev services**,
and feeds evidence back for a human to decide. It never holds production
credentials.

> **Stack note (current direction).** The demo focus is **migrations in the
> pipeline, Tiger Cloud as the agentic database, and the agents** — not SQL
> mechanics. The sample app is **TypeScript + Prisma**, and **Prisma owns both
> the models and the migrations** (`prisma migrate` applies DDL directly). There
> is no separate migration tool. Prior drafts used pgroll, then briefly
> Liquibase; both are dropped. pgroll specifically does **not work on Tiger
> Cloud** — it needs superuser to create event triggers, which Tiger Cloud does
> not grant — which is what drove the move to an ORM-native migrate flow. The
> AWS agent analysis in this document (Options A–D) is independent of that
> choice; only the "migration tool" the agent drives changed.

> Scope reminder from `.kiro/steering/automation.md`: everything is fully coded
> and automated, GitHub Actions is the authoring surface running on an **AWS
> CodeBuild-hosted runner**, IaC is **OpenTofu** (region `us-east-1`), secrets
> live in **AWS Secrets Manager**, and the agent is **dev-scoped only**. These
> options are evaluated against those rules.

---

## TL;DR recommendation

- **Decided: Option B — Strands Agents on AgentCore Runtime.** Code-first agent
  loop you can version in-repo, LLM-agnostic (Bedrock-backed by preference),
  deployed as a container to a managed, session-isolated runtime. Best fit for
  "fully coded, no manual steps," least-privilege IAM, and the CodeBuild/OpenTofu
  stack.
The agent runs on AgentCore; CodeBuild hosts the GitHub
  Actions pipeline that *invokes* it.

---

## Two agent roles — this is not "Kiro vs AWS"

The charter describes **two different agent jobs**, and the right technology
differs per job. They compose; they do not compete.

### Role 1 — Orchestrator / reasoner: **kirocrew (Bedrock-backed)**

The agent that brainstorms candidate migration approaches, proposes several (not
one), supervises the dev-side work under guardrails, and hands a recommendation
back to a human. The charter already names this role: **kirocrew**, and says
"Prefer AWS-hosted (Bedrock-backed) kirocrew agents."

Key point: this is **not Kiro instead of AWS** — kirocrew runs **on Bedrock**, so
choosing it already satisfies the "prefer AWS agents" rule. For the
brainstorming + candidate-proposal + human-recommendation + dev-scoped
supervision role, **Kiro/kirocrew is the right technology**.

- Interactive / conversational: a human presents a problem, the agent proposes
  candidates, a human decides.
- Dev-scoped only — never holds production credentials.
- Bedrock-backed → satisfies "prefer AWS agents."

### Role 2 — Execution runtime: **Strands on AgentCore Runtime (DECIDED: Option B)**

The headless thing a GitHub Actions job **invokes non-interactively** to run one
migration candidate against one ephemeral Tiger Cloud service, with a
least-privilege IAM role, then tears down.

**Decided: the agent runs on Amazon Bedrock AgentCore Runtime (Option B).** It
does **not** run on the CodeBuild runner. The GitHub Actions workflow (hosted on
CodeBuild) *invokes* the agent on AgentCore; CodeBuild is the pipeline compute,
AgentCore is the AI compute. Option A below (agent-on-runner) is retained only as
a rejected alternative for context.

- Non-interactive, per-candidate, invoked by CI; agent executes in an AgentCore
  session (one session per candidate).
- Least-privilege execution role; disposable.
- Default model: **Amazon Nova Pro** (config variable; Sonnet/Opus 5.5 step-up).

### How they fit together

```
Human  ──problem──▶  kirocrew (Bedrock)        Role 1: orchestrator/reasoner
                        │  proposes candidates A/B/C/D
                        ▼
            GitHub Actions (CodeBuild runner)   pipeline compute: invokes agent
                        │  one job per candidate
                        ▼
        Agent on AgentCore Runtime               Role 2: AI compute (NOT CodeBuild)
                        │  provision → prisma migrate → analyze → teardown
                        ▼
            Ephemeral Tiger Cloud dev service (one per candidate)
                        │  Datadog collects evidence
                        ▼
Human  ◀──evidence──  compares candidates, decides; winner → gated prod path
```

So: **Kiro IS the right technology for Role 1** (and it is Bedrock-backed, which
keeps it AWS-native). **Options A/B are the right technology for Role 2.** The
rest of this document (A–D) is about Role 2.

---

## Background: the AWS agent stack (early 2026)

Three layers that compose, not three competing products
([dev.to overview](https://dev.to/aws/how-to-build-and-deploy-an-ai-agent-on-aws-with-bedrock-strands-and-agentcore-1n1n)):

- **Amazon Bedrock** — the managed model API (the "brain"). One `converse` /
  `converse_stream` interface over many models, with IAM, KMS, and CloudTrail
  attached. ([tutorialsdojo](https://tutorialsdojo.com/building-production-ai-agents-on-aws-agentcore-harness-strands-1-0-and-the-multi-agent-architecture-that-actually-ships/))
- **Strands Agents SDK** — the open-source harness that gives the model a tool
  loop. You write the agent in code (Python), pick the model, define tools. LLM-
  agnostic (Bedrock preferred here, but can target others).
- **Amazon Bedrock AgentCore** — managed production substrate: session-isolated
  Firecracker microVMs, up to ~8-hour tasks, plus building blocks for memory,
  gateway/tools, browser, sandboxed code execution, and observability. You bring
  your own container and deploy it. ([tutorialsdojo](https://tutorialsdojo.com/building-production-ai-agents-on-aws-agentcore-harness-strands-1-0-and-the-multi-agent-architecture-that-actually-ships/),
  [Spring AI SDK GA post](https://aws.amazon.com/jp/blogs/machine-learning/spring-ai-sdk-for-amazon-bedrock-agentcore-is-now-generally-available/))

Content from the sources above was rephrased for compliance with licensing
restrictions.

---

## Option A — Strands Agents SDK on the CodeBuild runner (no separate runtime) — ❌ REJECTED

> **Not chosen.** The AI agent runs on **AgentCore (Option B)**, not on the
> CodeBuild runner. CodeBuild hosts the GitHub Actions pipeline only; it does
> not execute the agent. This option is kept below as context for *why* a
> managed runtime was preferred — do not implement it.

Run the agent loop as a Python process **inside the existing CodeBuild-hosted
GitHub Actions runner**. Strands drives Bedrock for reasoning; the agent's
"tools" are the repo's existing scripts (`provision_dev_service.sh`,
`apply_migrations.sh`, `detect_lock_rewrite.sh`, `analyze_gate.sh`, Tiger CLI,
`prisma migrate`, iqtoolkit-analyzer).

**Fit with charter**
- Fully coded, no new managed service; the agent is just code the workflow runs.
- Reuses the CodeBuild compute and its scoped IAM role (already gets
  `secretsmanager:GetSecretValue` on the dev secret only).
- Dev-scoped by construction — the runner never has prod credentials.

**Pros**
- Smallest footprint; nothing new to provision beyond the runner.
- Easiest to reason about for a workshop demo.
- Agent logic lives in-repo, versioned, reviewable.

**Cons**
- No managed session isolation/memory; you own the loop lifecycle.
- Long parallel bake-offs (four candidates) share one CI compute unless you fan
  out across jobs.

**IaC / infra to add (OpenTofu)**
- Bedrock model invocation permission (`bedrock:InvokeModel` /
  `bedrock:Converse*`) on the runner role, scoped to the chosen model ARN(s).
- No new runtime resources.

**When to pick:** you want the demo working with the least new infrastructure and
are comfortable orchestrating parallelism via GitHub Actions matrix jobs.

---

## Option B — Strands Agents on AgentCore Runtime (recommended)

Package the Strands agent as a container and deploy it to **AgentCore Runtime**.
GitHub Actions (on CodeBuild) invokes the agent per candidate; AgentCore gives
each candidate its own isolated, ephemeral session.

**Fit with charter**
- Still fully coded (agent is a container built from repo source).
- Session isolation maps cleanly onto "spin up N candidates in parallel, each
  isolated" — one AgentCore session per candidate Tiger service.
- Managed observability dovetails with the Datadog layer; AgentCore handles the
  runtime, Datadog handles the Postgres/migration signals.
- Dev-scoped: the agent's execution role gets only dev-side permissions.

**Pros**
- Managed, isolated sessions (Firecracker microVMs); long-running tasks
  supported — good for backfill-heavy candidates. ([tutorialsdojo](https://tutorialsdojo.com/building-production-ai-agents-on-aws-agentcore-harness-strands-1-0-and-the-multi-agent-architecture-that-actually-ships/))
- Clean separation between orchestration (GitHub Actions) and agent execution.
- LLM-agnostic; Bedrock-backed by default per the "prefer AWS agents" rule.
- Scales the parallel bake-off without contending for CI compute.

**Cons**
- More infrastructure: container build + registry (ECR) + AgentCore runtime +
  execution role.
- Newer managed surface; pin versions. (AgentCore Runtime is **GA in
  `us-east-1`** — confirmed for this account, so no preview risk on the runtime
  itself; still version-pin anything built on top.)

**IaC / infra to add (OpenTofu)**
- ECR repo for the agent image; image build in CI.
- AgentCore runtime resource + agent execution role (least-privilege: Bedrock
  invoke on chosen model, `secretsmanager:GetSecretValue` on the dev secret ARN
  only, Tiger/Datadog egress as needed).
- Region-pinned `us-east-1`.

**Provisioning AgentCore in OpenTofu (verified).** AgentCore Runtime instances
went **GA (Aug 2026)** and the runtime is exposed as the CloudFormation resource
`AWS::BedrockAgentCore::Runtime`, so it is provisionable via the **`awscc`**
provider (AWS Cloud Control, generated from the CloudFormation schema) as
**`awscc_bedrockagentcore_runtime`**. The AWS Cloud Control API also means
anything not yet in the classic `aws` provider is reachable through `awscc`.
Required properties: `agent_runtime_artifact` (the ECR container image),
`agent_runtime_name`, and `role_arn` (the execution role). Optional:
`network_configuration`, `environment_variables`, `protocol_configuration`
(`MCP | HTTP | A2A | AGUI`), `description`, tags. Returns `agent_runtime_arn`,
`agent_runtime_id`, `status`. (Schema confirmed against the CloudFormation
resource reference; pin the `awscc` provider version and run `tofu plan` to
confirm attribute names against the installed provider before apply.)

Sources: [AWS::BedrockAgentCore::Runtime (CloudFormation ref)](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-bedrockagentcore-runtime.html),
[AgentCore Runtime GA](https://aws.amazon.com/about-aws/whats-new/2026/08/aws-bedrock-agentcore-runtime-instances-generally-available/).
Content rephrased for licensing compliance.

**When to pick:** you want the production-shaped answer that still demos well —
isolated parallel candidates, managed runtime, clean IAM boundaries.

---

## Option C — AgentCore with the managed "harness" / higher-level building blocks

Use AgentCore's higher-level pieces (harness, Gateway for tools, Memory) to
assemble the agent with less bespoke loop code. The harness was announced in
public preview on **April 22, 2026**. ([awsfundamentals](https://awsfundamentals.com/blog/bedrock-agentcore-harness))

**Fit with charter**
- Still code/config in-repo; leans on managed building blocks for memory and
  tool wiring (Gateway can expose the repo scripts/MCP tools to the agent).

**Pros**
- Less loop plumbing to write and maintain.
- Built-in memory + tool gateway + observability.

**Cons**
- Preview-stage features — risky to pin a workshop/demo to; verify GA state and
  version-pin per the charter's "pin tool versions" rule.
- Less direct control over the step-by-step decision loop than raw Strands.

**When to pick:** you want managed memory/tool-gateway and can tolerate
preview-stage surface area, or you are building past the workshop into a
longer-lived product.

---

## Option D — Bedrock Agents Classic (not recommended)

The original 2023 configuration-driven Bedrock Agents.

**Status:** now **Agents Classic**, in maintenance mode, **closed to new
customers starting July 30, 2026**; AWS directs new builds to AgentCore.
([AWS docs](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html))

**Why it's a poor fit here**
- Closed product: Lambda-based tool execution, Knowledge Bases for retrieval,
  Bedrock-only models, and limited visibility into per-step decisions.
  ([dev.to](https://dev.to/aws-builders/cracking-the-bedrock-reaching-the-core-building-agents-with-aws-agentcore-runtime-and-memory-32kg))
- Config-driven rather than fully coded in-repo — rubs against "everything is
  code" and the scripted-translation ethos of this demo.
- Being sunset for new customers; not a durable foundation.

**When to pick:** only if an existing Classic agent must be reused. For a new
build, prefer A/B/C.

Content from the sources above was rephrased for compliance with licensing
restrictions.

---

## Decision matrix

| Criterion | A: Strands on runner | B: Strands on AgentCore | C: AgentCore harness | D: Agents Classic |
|---|---|---|---|---|
| Fully coded in-repo | High | High | Medium | Low |
| New infra to provision | Minimal | Moderate (ECR + runtime) | Moderate | Low (but deprecated) |
| Session isolation for parallel candidates | Manual (CI matrix) | Managed | Managed | Limited |
| Long-running backfill support | Limited by CI | Strong (~8h) | Strong | Limited |
| Control over decision loop | Full | Full | Partial | Low |
| Future-proof (2026+) | Good | Strong | Strong (preview caveats) | Being sunset |
| Demo simplicity | Highest | Medium | Medium | Low |

---

## Decided path for this repo

1. **Option B — the agent runs on AgentCore Runtime.** No staging through
   Option A: the AI + Tiger Cloud + pipeline thesis makes AgentCore the AI
   compute plane from the start. One AgentCore session per candidate for the
   parallel bake-off, with session isolation and long-running task support.
2. **CodeBuild hosts the GitHub Actions pipeline only** — it *invokes* the agent
   on AgentCore; it does not run the agent. Two distinct planes.
3. **Default model: Amazon Nova Pro** (AWS-native, cost-efficient), kept as a
   config variable (`BEDROCK_MODEL_ID`); Claude Sonnet 5.5 / Opus 5.5 are the
   documented step-up. Confirm the exact id is enabled in the `us-east-1`
   account before first invoke.
4. Keep all infra in **OpenTofu** (`us-east-1`), secrets in **Secrets Manager**,
   and the agent execution role **least-privilege and dev-scoped** — no prod
   credentials, prod stays behind the human-approved GitHub Environment.

### Next buildable steps (all code, no manual steps)
- `app/` TypeScript + Prisma sample app: Prisma schema (models own the schema),
  `prisma migrate` as the migration applier, a lightweight ingest/read loop, and
  ddtrace/Datadog instrumentation.
- `agent/` Python package: Strands agent + tool definitions wrapping the repo
  scripts (`scripts/*.sh`), Tiger CLI, the Prisma migrate flow
  (`prisma migrate deploy` as the CI applier), iqtoolkit-analyzer.
- OpenTofu module for the agent execution role (+ ECR + AgentCore runtime for
  Option B), region-pinned `us-east-1`, least-privilege.
- GitHub Actions job (on the CodeBuild runner) that invokes the agent per
  candidate and collects the evaluation evidence for the human decision.

---

### Sources
- [AWS: AgentCore runtime](https://aws.amazon.com/blogs/machine-learning/the-new-agentcore-runtime-elastic-optimized-and-consistently-fast-starts/)
- [AWS docs: Agents Classic maintenance mode](https://docs.aws.amazon.com/bedrock/latest/userguide/agents-classic-maintenance-mode.html)
- [dev.to: Bedrock + Strands + AgentCore](https://dev.to/aws/how-to-build-and-deploy-an-ai-agent-on-aws-with-bedrock-strands-and-agentcore-1n1n)
- [tutorialsdojo: AgentCore + Strands 1.0](https://tutorialsdojo.com/building-production-ai-agents-on-aws-agentcore-harness-strands-1-0-and-the-multi-agent-architecture-that-actually-ships/)
- [awsfundamentals: AgentCore harness preview](https://awsfundamentals.com/blog/bedrock-agentcore-harness)
- [dev.to: Cracking the Bedrock (AgentCore runtime + memory)](https://dev.to/aws-builders/cracking-the-bedrock-reaching-the-core-building-agents-with-aws-agentcore-runtime-and-memory-32kg)

_Content from external sources was rephrased for compliance with licensing restrictions._
