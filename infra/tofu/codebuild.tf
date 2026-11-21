# Phase 2 — Dedicated CodeBuild project that hosts the GitHub Actions runner.
#
# Mechanism: this is a CodeBuild "GitHub Actions runner" project. Its webhook is
# filtered on WORKFLOW_JOB_QUEUED, so when a GitHub Actions job targets this
# runner (via runs-on labels referencing this project), GitHub emits a
# workflow_job event, CodeBuild receives it on the webhook, and runs an
# ephemeral build that registers as the self-hosted runner for that one job.
#
# GitHub <-> AWS auth is via AWS CodeConnections (see connection.tf). The
# connection must be AUTHORIZED in the console once (it is created PENDING).

# Register the authorized CodeConnections connection as CodeBuild's GitHub
# credential. CodeBuild uses ONE GitHub credential per account per region (set
# as the default for the GITHUB provider); this is what gives the project
# permission to create the webhook. The token is the connection's ARN (a
# resource reference — NOT a hardcoded value).
#
# NOTE: this sets/overrides the ACCOUNT+REGION-WIDE default GitHub credential
# for CodeBuild in us-east-1. This demo's CodeBuild project is the only one, so
# that is intended.
resource "aws_codebuild_source_credential" "github" {
  auth_type   = "CODECONNECTIONS"
  server_type = "GITHUB"
  token       = aws_codeconnections_connection.github.arn
}

resource "aws_codebuild_project" "runner" {
  name         = "agentic-dataops-runner"
  description  = "Dedicated GitHub Actions runner for agentic-dataops (ephemeral, CodeBuild-hosted)."
  service_role = aws_iam_role.codebuild_runner.arn

  # The repo this runner serves. CodeConnections provides the credential.
  source {
    type     = "GITHUB"
    location = "https://github.com/${var.github_owner}/${var.github_repo}.git"
  }

  # Ephemeral runner: no persistent artifacts.
  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = var.codebuild_compute_type
    image                       = var.codebuild_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # needed to run docker (liquibase image) in jobs
  }

  # VPC-attach the runner so jobs run INSIDE vpc-0123456789abcdef1 and can reach
  # the private RAG Tiger store over the VPC peering (e.g. rag-migrate.yml runs
  # Liquibase directly). Private subnets (var.agent_subnet_ids) default-route via
  # NAT and have the VPC interface endpoints, so jobs still reach GitHub, ECR,
  # Secrets Manager, etc.
  vpc_config {
    vpc_id             = var.rag_peer_vpc_id
    subnets            = var.agent_subnet_ids
    security_group_ids = [aws_security_group.codebuild_runner.id]
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.runner.name
    }
  }

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "github-actions-runner"
    ManagedBy = "opentofu"
  }
}

# Security group for the VPC-attached runner. This is a general-purpose CI
# runner: besides reaching the private RAG Tiger store (5432 over peering), its
# build jobs legitimately need arbitrary OUTBOUND access — apt mirrors (port 80,
# http://archive.ubuntu.com), HTTPS registries (ECR, GitHub, Docker Hub via the
# pull-through cache, Maven Central), etc. Restricting egress to a couple of
# ports breaks image builds (e.g. apt on port 80), so we allow all egress. This
# is egress-only; there is no ingress rule (nothing connects IN to the runner).
resource "aws_security_group" "codebuild_runner" {
  name_prefix = "agentic-dataops-runner-"
  description = "VPC-attached CodeBuild runner: all egress (CI needs arbitrary outbound) incl. 5432 to the RAG Tiger CIDR."
  vpc_id      = var.rag_peer_vpc_id

  # Rules live in a SEPARATE resource (below), so changing egress NEVER deletes/
  # replaces this SG — avoiding the DependencyViolation when the CodeBuild
  # project's vpc_config still references it. name_prefix (not a fixed name)
  # lets create_before_destroy swap the SG without a name collision if a replace
  # is ever truly needed.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

# All egress for the runner, as an independent rule resource (changing it does
# not touch the SG). Protocol -1 / all ports = allow all outbound.
resource "aws_vpc_security_group_egress_rule" "codebuild_runner_all" {
  security_group_id = aws_security_group.codebuild_runner.id
  description       = "All outbound (apt/80, HTTPS/443, registries, GitHub, 5432 to the RAG store over peering)."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

resource "aws_cloudwatch_log_group" "runner" {
  name              = "/codebuild/agentic-dataops-runner"
  retention_in_days = 30

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

# Webhook that turns this project into a GitHub Actions runner backend.
# WORKFLOW_JOB_QUEUED is the event CodeBuild uses for the Actions-runner feature.
resource "aws_codebuild_webhook" "runner" {
  project_name = aws_codebuild_project.runner.name
  build_type   = "BUILD"

  filter_group {
    filter {
      type    = "EVENT"
      pattern = "WORKFLOW_JOB_QUEUED"
    }
  }

  # The source credential must exist first, or CreateWebhook fails with
  # "Repository not found or permission denied".
  depends_on = [aws_codebuild_source_credential.github]
}
