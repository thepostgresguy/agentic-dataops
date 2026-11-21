# Step-by-Step: Create an Agent That Uses a Tiger Cloud Service

This guide builds the **execution-runtime agent** (Role 2 in
[`aws-agent-options.md`](./aws-agent-options.md)) — the headless agent that a
GitHub Actions job invokes to run a migration candidate against an **ephemeral
Tiger Cloud dev service**, then tears it down. It uses this repo's existing
scripts as the agent's tools.

The reasoning/orchestration agent (Role 1) is **kirocrew (Bedrock-backed)** and
is not provisioned here; this guide is the thing kirocrew supervises.

> **Stack:** TypeScript + Prisma sample app; **Prisma owns both models and
> migrations** (`prisma migrate` applies DDL — no separate migration tool). The
> Strands agent itself is still Python; it just shells out to `prisma migrate`.
> Focus: **migrations in the pipeline, Tiger Cloud as the agentic database, and
> the agents** — not SQL mechanics.
>
> History: the demo originally used pgroll as the migration applier, but moved
> off it because pgroll needs superuser to create the event triggers it relies
> on, which Tiger Cloud does not grant. Prisma is now the applier — it owns both
> the models (`schema.prisma`) and the committed migration SQL under
> `prisma/migrations/`, applied in CI via `prisma migrate deploy`.

> Everything below is **code and CI** per the automation charter. There are no
> manual `prisma`, `psql`, or database-creation steps run by a human. No local
> databases — every DSN points at a Tiger Cloud service. Commands are shown so
> you can read what the automation does, not so you run them by hand.

---

## What you are building

A containerized Strands agent (Bedrock-backed by preference) whose **tools** wrap
the repo's guardrail scripts and the Prisma CLI:

| Agent tool | Wraps | Purpose |
|---|---|---|
| `provision_dev_service` | `scripts/provision_dev_service.sh` | create ephemeral Tiger service, return DSN + service_id |
| `detect_lock_rewrite` | `scripts/detect_lock_rewrite.sh` | fail on unsafe lock/rewrite (static SQL check) |
| `migrate_deploy` | `scripts/apply_migrations.sh ... deploy` | apply committed Prisma migrations (`prisma migrate deploy`) |
| `migrate_status` | `scripts/apply_migrations.sh ... status` | report migration status |
| `analyze_gate` | `scripts/analyze_gate.sh` | iqtoolkit-analyzer thresholds gate |
| `teardown_dev_service` | `scripts/teardown_dev_service.sh` | always-run cleanup |

The agent's job per candidate: provision → detect → deploy → analyze →
**teardown**, emitting evidence for the human.

---

## Prerequisites (all provisioned as code)

1. **AWS account**, region `us-east-1` (charter default).
2. **OpenTofu** (`tofu`) for all IaC — the CodeBuild runner, IAM, Secrets Manager
   references. No CloudFormation, no raw Terraform CLI.
3. **AWS Secrets Manager** secret `agentic-dataops/tiger/dev` (JSON) holding the
   Tiger Cloud keys (and Datadog API/APP keys alongside). No secrets in GitHub.
4. **Bedrock model access** enabled in `us-east-1` for the model the agent uses.
   > AgentCore Runtime is **GA in `us-east-1`** (confirmed for this account).
   > Still verify the specific Bedrock *model* is enabled in the account — model
   > access is separate from AgentCore availability.
5. CLIs available on the runner image, **version-pinned**: Tiger CLI, Node/npm +
   `prisma`, `iqtoolkit-analyzer`, `psql`, `jq`.

---

## Step 1 — Store Tiger Cloud credentials in Secrets Manager (OpenTofu)

The secret holds the Tiger public/secret keys the Tiger CLI uses to provision
services. The runner reads it via a scoped IAM policy — least privilege, one
secret ARN only.

```hcl
# infra/secrets.tf  (region-pinned us-east-1)
resource "aws_secretsmanager_secret" "tiger_dev" {
  name = "agentic-dataops/tiger/dev"
}

# Value is set out-of-band (not committed). Shape:
# { "TIGER_PUBLIC_KEY": "...", "TIGER_SECRET_KEY": "...",
#   "DD_API_KEY": "...", "DD_APP_KEY": "..." }
```

> Never commit the secret value. OpenTofu creates the container; the keys are
> populated via a secure channel outside version control.

## Step 2 — Give the agent's execution role least-privilege access (OpenTofu)

The agent runs on **AgentCore Runtime** (decided; it does NOT run on the
CodeBuild runner — CodeBuild only hosts the GitHub Actions pipeline that invokes
the agent).
Its role gets exactly three things: read the one secret, invoke the Bedrock
model, nothing on production.

```hcl
# infra/iam.tf
data "aws_iam_policy_document" "agent_exec" {
  statement {
    sid       = "ReadTigerDevSecretOnly"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.tiger_dev.arn]
  }
  statement {
    sid       = "InvokeBedrockModel"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [var.bedrock_model_arn] # scope to the chosen model ARN
  }
}
```

No `secretsmanager:*`, no wildcard resources, no production credentials. This
enforces charter rule 5 (agents are dev-scoped) and rule 10 (least privilege on
one secret ARN).

## Step 3 — Define the agent and its tools (Strands)

Each tool is a thin wrapper that shells out to an existing repo script and
returns structured output. Pin the model; keep the loop in-repo and reviewable.

```python
# agent/migration_agent.py  (illustrative Strands shape)
import os, subprocess
from strands import Agent, tool

SCRIPTS = "scripts"
# Path to the TypeScript/Prisma app whose migrations the agent applies.
PRISMA_APP = "app"

def _run(args: list[str], cwd: str | None = None, env: dict | None = None) -> str:
    # Fixed command paths; candidate/DSN values are passed as args / env (no
    # shell string interpolation) — treat all output as untrusted.
    return subprocess.run(
        args, check=True, capture_output=True, text=True, cwd=cwd,
        env={**os.environ, **(env or {})},
    ).stdout

@tool
def provision_dev_service(name: str, region: str = "us-east-1") -> dict:
    """Create an ephemeral Tiger Cloud dev service; return {service_id, dsn}."""
    out = _run([f"{SCRIPTS}/provision_dev_service.sh", name, region])
    dsn = out.strip().splitlines()[-1]  # script prints DSN as last line
    return {"dsn": dsn}

@tool
def detect_lock_rewrite(migration_path: str) -> str:
    """Static SQL guardrail: fail on unsafe lock/rewrite DDL (offline, no DB)."""
    return _run([f"{SCRIPTS}/detect_lock_rewrite.sh", migration_path])

@tool
def migrate_deploy(dsn: str, prisma_dir: str = "prisma") -> str:
    """Apply committed Prisma migrations non-interactively (prisma migrate deploy)."""
    return _run([f"{SCRIPTS}/apply_migrations.sh", dsn, "deploy", prisma_dir])

@tool
def analyze_gate(dsn: str) -> str:
    return _run([f"{SCRIPTS}/analyze_gate.sh", dsn])

@tool
def teardown_dev_service(service_id: str) -> str:
    return _run([f"{SCRIPTS}/teardown_dev_service.sh", service_id])

agent = Agent(
    # Resolved from BEDROCK_MODEL_ID at runtime (see "Model selection" below);
    # placeholder here, never a hard-coded real id.
    model=os.environ["BEDROCK_MODEL_ID"],
    tools=[provision_dev_service, detect_lock_rewrite, migrate_deploy,
           analyze_gate, teardown_dev_service],
    system_prompt=(
        "You evaluate ONE PostgreSQL migration candidate against ONE ephemeral "
        "Tiger Cloud dev service. Provision, run the static lock/rewrite "
        "guardrail, apply the committed Prisma migration (prisma migrate "
        "deploy), run the analyzer gate, collect evidence, then ALWAYS tear "
        "down the service. You are dev-scoped: never touch production. Report "
        "evidence; do not decide the winner."
    ),
)
```

### Model selection

AgentCore Runtime is **model-agnostic** — it hosts the agent code; the code
chooses the model. Per charter rule 7 ("always prefer AWS agents"), the agent
calls a **Bedrock** model via the AgentCore `bedrock-mantle` connector, not a
third-party API (which would add a non-AWS key + egress path the charter avoids).

The chosen model is **"the best and most appropriate AWS/Bedrock model"** at
deploy time — kept as a **single config variable**, never hard-coded, so it can
track whatever Bedrock model is current and enabled without a code change:

- A strong reasoning tier (Claude Sonnet/Opus-class) for the candidate
  brainstorming and evidence-judging work.
- Optionally a cheaper tier (Haiku / Nova-class) for rote tool-calling steps, to
  respect the cost-discipline rule during the four-way bake-off.

Resolution order: `BEDROCK_MODEL_ID` env var → OpenTofu `var.bedrock_model_arn`
→ fail fast if unset. The specific id must be **enabled in-account** in
`us-east-1` (`aws bedrock list-foundation-models --region us-east-1`) — AgentCore
being model-agnostic does not grant model access; that is a separate toggle. A
wrong/unenabled id passes config validation but fails at the first invoke, so
validate it before deploy.

## Step 4 — Containerize the agent (charter: containerized, no local runs)

The agent is Python, but it shells out to the **Prisma CLI (Node.js)**, so the
image needs both runtimes.

```dockerfile
# agent/Dockerfile
FROM public.ecr.aws/docker/library/python:3.12-slim
# Pin tool versions per charter rule "Pin tool versions".
RUN apt-get update && apt-get install -y --no-install-recommends \
      postgresql-client jq ca-certificates curl && rm -rf /var/lib/apt/lists/*
# Node.js + Prisma CLI (pin exact versions — placeholders below).
# e.g. install Node LTS, then: npm install -g prisma@<pinned>
# Install pinned Tiger CLI and iqtoolkit-analyzer here (versions pinned).
COPY agent/ /app/agent/
COPY scripts/ /app/scripts/
COPY app/ /app/app/          # TypeScript/Prisma app (schema + migrations)
WORKDIR /app
RUN pip install --no-cache-dir strands-agents boto3
# Prisma deps for the app (prisma client/CLI) installed from app/package.json.
ENTRYPOINT ["python", "-m", "agent.migration_agent"]
```

> **Decided (Option B):** this image is pushed to ECR and deployed to
> **AgentCore Runtime** for isolated, parallel per-candidate sessions. It does
> NOT run on the CodeBuild runner — the GitHub Actions workflow (hosted on
> CodeBuild) invokes the agent on AgentCore.

## Step 5 — How the agent gets Tiger credentials at runtime

The agent's **AgentCore execution role** (Step 2) reads the secret; the agent's
container entrypoint loads the Tiger keys into the environment the Tiger CLI
expects. No keys in GitHub, none in the image.

```bash
# entrypoint shim (runs inside the AgentCore session before the agent loop)
creds="$(aws secretsmanager get-secret-value \
  --secret-id agentic-dataops/tiger/dev \
  --region us-east-1 --query SecretString --output text)"
export TIGER_PUBLIC_KEY="$(jq -r .TIGER_PUBLIC_KEY <<<"$creds")"
export TIGER_SECRET_KEY="$(jq -r .TIGER_SECRET_KEY <<<"$creds")"
export DD_API_KEY="$(jq -r .DD_API_KEY <<<"$creds")"
# Tiger CLI now authenticates non-interactively.
```

## Step 6 — The Tiger Cloud lifecycle the agent drives (per candidate)

This is exactly what `provision_dev_service.sh` and `teardown_dev_service.sh`
already do, invoked by the agent's tools:

```
tiger service create --name <candidate> --region us-east-1 \
     --output json --no-wait=false      # block until ready
service_id = parse(.service_id)          # from JSON
dsn        = tiger db uri --service-id <id> --pooled=false
# DATABASE_URL=<dsn> npx prisma migrate deploy   (in app/)  + lock/analyze gates
tiger service delete --service-id <id> --confirm   # ALWAYS, even on failure
```

Charter rules enforced here: ephemeral service per run (rule 8/11), no local DB
(rule 6), region `us-east-1` (rule 7), always torn down (cost discipline, rule
11).

## Step 7 — Invoke the agent from GitHub Actions (CodeBuild runner)

One job per candidate; the four candidates run in parallel via a matrix. Teardown
is `if: always()` so no service leaks.

```yaml
# .github/workflows/evaluate-candidates.yml  (illustrative)
jobs:
  evaluate:
    runs-on: [self-hosted, codebuild-agentic-dataops-runner]  # AWS CodeBuild runner
    strategy:
      matrix:
        candidate: [A, B, C, D]   # the four migration approaches
    steps:
      - uses: actions/checkout@v4
      - name: Run migration candidate agent
        run: python -m agent.migration_agent --candidate "${{ matrix.candidate }}"
      - name: Teardown ephemeral service
        if: always()
        run: scripts/teardown_dev_service.sh "${SERVICE_ID}"
```

The agent itself only ever touches the dev service. Promotion to production stays
behind the human-approved GitHub Environment (charter rule 5) and is a separate,
gated workflow — out of scope for this agent.

## Step 8 — Evidence out, human decides

Each candidate job emits its evaluation (lock level + hold time, rewrite yes/no,
backfill duration, ingest p50/p95, WAL/storage delta, correctness,
analyzer findings) to **Datadog** (dashboards + migration-phase Events). The
human compares the four side by side and picks the winner. The agent recommends
and reports; it never gets the final word (charter: "the agent never gets the
final word").

---

## Checklist

- [ ] Secrets Manager secret `agentic-dataops/tiger/dev` created (OpenTofu)
- [ ] Agent execution role: `GetSecretValue` on that ARN + `bedrock:InvokeModel`
      only; no prod access
- [ ] Bedrock model access confirmed in `us-east-1`
- [ ] `app/` TypeScript + Prisma app (schema = models; `prisma migrate` applies)
- [ ] `agent/` package with tools wrapping `scripts/*.sh` + `prisma migrate`
- [ ] `agent/Dockerfile` with pinned Tiger CLI / Node + Prisma / iqtoolkit-analyzer
- [ ] GitHub Actions matrix job on the CodeBuild runner, teardown `if: always()`
- [ ] Datadog receiving per-candidate evidence + migration Events
- [ ] No local DB, no manual migrations (Prisma applies in CI), no secrets in GitHub

---

## Notes on accuracy

The agent code (Strands shapes), Dockerfile, and workflow above are
**illustrative scaffolds**, not verified against your AWS account or pinned
tool versions. AgentCore Runtime is **GA in `us-east-1`** (confirmed). Before
building: confirm the specific Bedrock model is enabled in `us-east-1`, pin
exact CLI versions (Node, Prisma, Tiger CLI, iqtoolkit-analyzer), and verify the
Tiger CLI subcommand surface (`tiger service create` / `tiger db uri` / `tiger
service delete`) matches the installed CLI — this repo's
`provision_dev_service.sh` and `teardown_dev_service.sh` already encode the
expected flags and tolerate CLI variation. The repo scripts are the source of
truth for the actual commands.

## Open items (not yet decided)

- **int4 → bigint zero-downtime demo is KEPT.** The demo deliberately shows the
  ORM making automatic decisions about how to convert `id` to `bigint` and the
  consequences of those actions (e.g. a naive `ALTER TABLE` rewriting a 2 TB
  table). Prisma's generated migration is the starting point; where it would
  emit a locking rewrite, the candidate's committed migration SQL is
  hand-authored to stay online. The live dual-read moment is demonstrated this
  way rather than via an external version-schema tool.
- **Candidate migration files.** Each candidate (A/B/C/D) needs its own Prisma
  migration(s); none exist yet. The matrix wires the mechanism; the
  per-candidate migrations are authored separately.
