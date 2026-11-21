# infra/tofu — OpenTofu infrastructure

All infrastructure for this project is defined as OpenTofu (`tofu`), region
`us-east-1`. It is bootstrapped in phases. The human owns `apply`.

## Status

- ✅ **Phase 1 — S3 state bucket** — applied; state migrated to S3.
- ✅ **Phase 2 — CodeBuild runner + IAM + GitHub connection** — applied.
  (Confirm the CodeConnections connection is **AVAILABLE**, not `PENDING` — see
  below.)
- ✅ **Phase 3 — CI-driven Tofu workflow** — `.github/workflows/tofu.yml`.
- ✅ **Later phases** — the app runtime, Tiger services, RAG store, AI agent and
  supporting resources (see [Resource map](#resource-map)). `deploy.yml` also
  runs `tofu apply` for the app runtime.

## Resource map

| File | What it defines |
|---|---|
| `s3.tf`, `backend.tf` | State bucket and the S3 backend |
| `codebuild.tf`, `connection.tf`, `iam.tf` | The CodeBuild GitHub Actions runner, its IAM role, the GitHub connection |
| `tiger_dev_secret.tf` | `agentic-dataops/tiger/dev` (Tiger CLI credentials, value set out-of-band) |
| `rag.tf` | Private RAG Tiger service, its VPC and peering, and the `agentic-dataops/tiger/rag` secret (written by Tofu) |
| `app_service.tf`, `app_db_secret.tf` | Private app Tiger service and the `agentic-dataops/app/database-url` secret (written by Tofu) |
| `ecr.tf`, `ecr_pullthrough.tf`, `ecr_pullthrough_secret.tf` | ECR repos (app image is immutable-tagged) and the Docker Hub pull-through cache |
| `ecs.tf`, `alb.tf`, `acm.tf` | ECS Fargate service for the app, the ALB, and the TLS certificate |
| `vpc_endpoints.tf` | VPC interface endpoints so the private runner and tasks reach AWS APIs |
| `agent.tf` | The AI consultant on Bedrock AgentCore Runtime (created once an image tag exists) |
| `providers.tf`, `variables.tf`, `outputs.tf` | Providers (`aws`, `awscc`, `timescale`), inputs and outputs |

The `timescale` provider needs Tiger credentials at plan time, so run Tofu
through `tofu-with-tiger-creds.sh` (it reads `agentic-dataops/tiger/dev` and
exports `TF_VAR_ts_*`). Bare `tofu plan` fails with
`No value for required variable "ts_access_key"`.

---

## Phase 1 — the S3 state bucket ✅ (done)

The dedicated S3 bucket `<your-state-bucket>` (versioning, SSE,
public-access blocked) holds the OpenTofu remote state. It was created with the
**local backend** (an S3 backend can't store the state of the bucket that backs
it), then state was migrated into S3.

Applied with:

```bash
cd infra/tofu
tofu init
tofu fmt -check
tofu validate
tofu plan -input=false
tofu apply -input=false
```

### Phase 1b — state migrated to S3 ✅ (done)

The `backend "s3"` block in `backend.tf` is active, and state was migrated:

```bash
tofu init -migrate-state   # answered "yes" to copy local state into S3
```

State now lives at `s3://<your-state-bucket>/bootstrap/terraform.tfstate`.
The local `terraform.tfstate` is no longer the source of truth.

---

## Phase 2 — CodeBuild runner + IAM + GitHub connection ✅ (done)

Resources (files `codebuild.tf`, `connection.tf`, `iam.tf`):

- **`aws_codebuild_project.runner`** (`agentic-dataops-runner`) — the dedicated
  CodeBuild-hosted GitHub Actions runner. Its webhook is filtered on
  `WORKFLOW_JOB_QUEUED`: when a GitHub Actions job targets this runner, CodeBuild
  runs an ephemeral build that registers as the self-hosted runner for that job.
- **`aws_cloudwatch_log_group.runner`** — build logs (`/codebuild/
  agentic-dataops-runner`, 30-day retention).
- **`aws_codeconnections_connection.github`** — the GitHub ↔ AWS link.
- **`aws_iam_role.codebuild_runner`** — AWS-managed PowerUserAccess plus a
  scoped IAM-management add-on (deliberate exception to least-privilege; see
  `iam.tf`), and a scoped inline policy `tiger-secret-read` granting
  least-privilege `secretsmanager:GetSecretValue` on the ONE Tiger secret ARN
  (`var.tiger_secret_arn`).
- **`aws_secretsmanager_secret.tiger_dev`** (`agentic-dataops/tiger/dev`, file
  `tiger_dev_secret.tf`) — the dedicated, isolated Tiger Cloud dev-credentials
  secret. Tofu creates the CONTAINER ONLY; the human populates the value
  (JSON `{project_id, access_id, secret_key}`) out-of-band with the AWS CLI so
  the keys never touch Tofu state.

Applied with:

```bash
cd infra/tofu
tofu init          # (S3 backend)
tofu fmt -check
tofu validate
tofu plan -input=false
tofu apply -input=false
```

### ⚠️ One-time manual step: authorize the GitHub connection

A CodeConnections connection created by OpenTofu is created in **`PENDING`**
status by AWS design — it cannot be fully authorized from code. Complete the
handshake **once in the AWS console**:

> Developer Tools → Settings → **Connections** → select
> `agentic-dataops-github` → **Update pending connection** → authorize with
> GitHub.

Until the connection is **`AVAILABLE`**, the CodeBuild runner cannot clone the
repo. The connection ARN is emitted as the `codeconnections_connection_arn`
output.

---

## Phase 3 — CI-driven Tofu workflow ✅ (done)

`tofu.yml` is the GitHub Actions workflow (on-demand `workflow_dispatch`) that runs
`tofu init` → `fmt -check` → `validate` → `plan`, and `apply -auto-approve`
only when an explicit `action=apply` input is chosen. It runs **on the
AWS-hosted CodeBuild runner** (the runner assumes its IAM role — no AWS keys in
GitHub). The Tiger Cloud credentials come from the dedicated Secrets Manager
secret `agentic-dataops/tiger/dev` (JSON `{project_id, access_id, secret_key}`),
which the runner reads via its scoped `GetSecretValue` grant. All Tofu runs use
`-input=false` and `-no-color`.

---

## Notes

- `.gitignore` in this folder keeps OpenTofu state, `.terraform/`, and any
  `*.tfvars` out of version control.
- Secrets are never committed. Tiger credentials live in the dedicated
  Secrets Manager secret `agentic-dataops/tiger/dev` (container created by Tofu,
  value populated out-of-band via the AWS CLI); AWS auth is via the runner's IAM
  role (role assumption).
- Variables (`variables.tf`) default to the applied values: bucket
  `<your-state-bucket>`, repo `thepostgresguy/agentic-dataops`, region
  `us-east-1`, and the Tiger secret ARN. Override via `-var` / a `*.tfvars` file
  (git-ignored) if any differ.
- `codebuild_image` is pinned to `aws/codebuild/amazonlinux2-x86_64-standard:5.0`
  — bump deliberately if you need a newer image.
