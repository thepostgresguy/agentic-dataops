# Phase 5 — the DB-consultant agent on Amazon Bedrock AgentCore Runtime.
#
# The agent reads a Prisma migration and advises (hazards, safe alternatives).
# Runs on AgentCore (via the awscc provider — see providers.tf). Default model
# is Amazon Nova Pro.
#
# APPLY ORDER (the runtime needs a real image):
#   1. apply the ECR repo + IAM role below (agent_image_tag can be empty),
#      OR target them: tofu apply -target=aws_ecr_repository.agent \
#         -target=aws_iam_role.agent
#   2. build + push the agent image to that repo (tag = git SHA)
#   3. apply the runtime with the tag:
#      tofu apply -var agent_image_tag=<sha>
#   The runtime resource is created only when agent_image_tag is non-empty.

# --- ECR repo for the agent image ---
resource "aws_ecr_repository" "agent" {
  name                 = "agentic-dataops/agent"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "agent-image"
    ManagedBy = "opentofu"
  }
}

resource "aws_ecr_lifecycle_policy" "agent" {
  repository = aws_ecr_repository.agent.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images older than 14 days"
      selection    = { tagStatus = "untagged", countType = "sinceImagePushed", countUnit = "days", countNumber = 14 }
      action       = { type = "expire" }
    }]
  })
}

# --- Agent execution IAM role ---
# Trust principal is bedrock-agentcore.amazonaws.com (confirmed from the
# awscc_bedrockagentcore_runtime provider example).
resource "aws_iam_role" "agent" {
  name = "agentic-dataops-agent"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

# Least-privilege: invoke the Bedrock model, pull the agent image from ECR,
# write logs. (No prod, no Tiger write — it is an advisory agent.)
data "aws_iam_policy_document" "agent" {
  statement {
    sid    = "InvokeBedrockModel"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    # Nova Pro / inference profile (chat). This wildcard ALSO covers the Titan
    # embeddings-model invoke the RAG path needs — no separate embeddings
    # statement required. Scope to the specific model ARNs later if desired.
    resources = ["*"]
  }
  # Read the RAG tsdbadmin DSN secret (agentic-dataops/tiger/rag) so the
  # VPC-attached agent can connect to the private RAG store. Scoped to that one
  # secret ARN (referenced directly, not hardcoded) — least-privilege.
  statement {
    sid       = "ReadRagSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.rag_tsdbadmin.arn]
  }
  statement {
    sid    = "PullAgentImage"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = ["*"] # GetAuthorizationToken requires * ; image actions could scope to the repo
  }
  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "agent-exec"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.agent.json
}

# --- VPC attachment so the agent can reach the PRIVATE RAG store ---
# The RAG Tiger service is private-only, reachable solely over the VPC peering
# into var.rag_peer_vpc_id (the Tiger CIDR var.rag_tiger_cidr, e.g.
# 10.42.0.0/24). A PUBLIC-mode AgentCore runtime has no path to it, so the
# runtime is attached to that VPC.
#
# SUBNET CHOICE: the runtime is attached to the PRIVATE (NAT-routed) subnets
# only, NOT every subnet in the VPC. All subnets carry the peering route to the
# Tiger CIDR (so RAG reachability holds from any of them), but the VPC also has
# PUBLIC subnets (default route via the IGW) and a runtime should not sit in a
# public subnet. The private subnets default-route through the NAT gateway, so
# the agent reaches AWS APIs (Bedrock, Secrets Manager, ECR, logs) via the SG's
# 443 egress AND reaches the private RAG store over the peering. The specific
# private subnet ids are set via var.agent_subnet_ids (defaulted to the two
# NAT-routed subnets confirmed in this VPC).

# Security group for the VPC-attached agent runtime.
#   - egress 5432 to the Tiger CIDR: reach the private RAG Postgres over peering.
#   - egress 443 to 0.0.0.0/0: a VPC-attached runtime reaches AWS APIs
#     (Bedrock, Secrets Manager, ECR, logs) over the network rather than the
#     AWS service fabric. NOTE/FOLLOW-UP: this only works if the attached
#     subnets have a route to those APIs (NAT gateway or VPC interface
#     endpoints). The subnets here may be private without NAT/endpoints — if so,
#     add VPC endpoints or a NAT as a follow-up. The SG rules are added
#     regardless so the egress policy is in place.
resource "aws_security_group" "agent" {
  name        = "agentic-dataops-agent"
  description = "Egress for the VPC-attached AgentCore agent: Postgres to the RAG Tiger CIDR + 443 to AWS APIs."
  vpc_id      = var.rag_peer_vpc_id

  egress {
    description = "Postgres to the private RAG Tiger service over VPC peering."
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.rag_tiger_cidr]
  }

  # Agentic mode (migration-test): the agent's read-only tools connect to the
  # per-run EPHEMERAL Tiger service, which has a PUBLIC endpoint on a
  # service-specific high TCP port (not 5432), reached via the NAT. The host is
  # not known in advance, hence 0.0.0.0/0. Credentials are a per-run read-only
  # role; the agent's code only connects to the DSN it is handed.
  egress {
    description = "Postgres to per-run ephemeral Tiger services (public endpoint, high port) for read-only agent tools."
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS to AWS APIs (Bedrock, Secrets Manager, ECR, logs) while VPC-attached."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

# --- AgentCore Runtime (awscc) ---
# Image tag is resolved AUTOMATICALLY from ECR (newest pushed image) so a plain
# `tofu apply` always deploys the latest agent build — NO manual -var, NO
# hand-edited SHA (charter: everything coded, no manual steps). var.agent_image_tag
# remains an optional OVERRIDE (pin a specific SHA) but defaults to "" = auto.
#
# The data source is guarded by var.agent_image_auto: set it to false only for a
# first-ever apply before any image exists (otherwise the lookup errors on an
# empty repo). Once an image has been pushed, leave it true (the default).
data "aws_ecr_image" "agent_latest" {
  count           = var.agent_image_auto && var.agent_image_tag == "" ? 1 : 0
  repository_name = aws_ecr_repository.agent.name
  most_recent     = true
}

locals {
  # Prefer an explicit override; else the auto-resolved newest image tag.
  agent_resolved_tag = (
    var.agent_image_tag != "" ? var.agent_image_tag :
    (var.agent_image_auto ? try(data.aws_ecr_image.agent_latest[0].image_tags[0], "") : "")
  )
  agent_image_uri = "${aws_ecr_repository.agent.repository_url}:${local.agent_resolved_tag}"
}

resource "awscc_bedrockagentcore_runtime" "agent" {
  count = local.agent_resolved_tag != "" ? 1 : 0

  agent_runtime_name = "agentic_dataops_agent" # pattern: [a-zA-Z][a-zA-Z0-9_]{0,47}
  description        = "DB-consultant agent: reads Prisma migrations and advises on hazards/alternatives."
  role_arn           = aws_iam_role.agent.arn

  agent_runtime_artifact = {
    container_configuration = {
      container_uri = local.agent_image_uri
    }
  }

  # VPC mode so the agent can reach the PRIVATE RAG store (var.rag_tiger_cidr,
  # peering-only — see rag.tf). Schema VERIFIED against awscc ~> 1.30 via
  # `tofu providers schema -json`: awscc_bedrockagentcore_runtime's
  # network_configuration takes network_mode plus a nested network_mode_config
  # with `subnets` and `security_groups` (list(string)) — this differs from the
  # awscc_bedrockagentcore_harness example, which uses top-level vpc_subnet_ids
  # / vpc_security_group_ids.
  network_configuration = {
    network_mode = "VPC"
    network_mode_config = {
      subnets         = var.agent_subnet_ids
      security_groups = [aws_security_group.agent.id]
    }
  }

  environment_variables = {
    BEDROCK_MODEL_ID = var.bedrock_model_id
    LOG_LEVEL        = "INFO"
  }

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

output "agent_ecr_repository_url" {
  description = "ECR repo URL for the agent image."
  value       = aws_ecr_repository.agent.repository_url
}

output "agent_role_arn" {
  description = "Agent execution role ARN."
  value       = aws_iam_role.agent.arn
}

output "agent_runtime_arn" {
  description = "AgentCore runtime ARN (empty until agent_image_tag is set)."
  value       = try(awscc_bedrockagentcore_runtime.agent[0].agent_runtime_arn, "")
}
