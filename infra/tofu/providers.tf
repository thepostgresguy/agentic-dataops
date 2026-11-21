# Provider and OpenTofu version pinning for the agentic-dataops infrastructure.
#
# Phase 1 bootstrap: this configuration uses the DEFAULT LOCAL backend so the
# S3 state bucket can be created before any remote backend exists (an S3
# backend cannot store the state of the bucket that backs it — chicken/egg).
#
# AFTER you apply this and the bucket exists, migrate state to S3:
#   1. Uncomment the `backend "s3"` block in backend.tf.
#   2. Run:  tofu init -migrate-state
# See backend.tf and README.md for the exact steps.

terraform {
  # OpenTofu respects the `terraform` block. Pin versions per the charter
  # ("Pin tool versions").
  required_version = ">= 1.8.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    # AWS Cloud Control provider — used ONLY for AgentCore Runtime
    # (awscc_bedrockagentcore_runtime), which the classic aws provider does not
    # yet expose. awscc is HashiCorp-maintained and calls the Cloud Control API
    # directly (NO CloudFormation stacks); state lives in Tofu like any provider.
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.30"
    }
    # Tiger Cloud (Timescale) provider — manages PERMANENT (non-ephemeral) Tiger
    # services as Tofu resources, e.g. the long-lived RAG store (rag.tf). Needs
    # creds at PLAN time; see the provider block below.
    timescale = {
      source  = "timescale/timescale"
      version = "~> 2.14"
    }
  }
}

provider "aws" {
  region = var.region
}

provider "awscc" {
  region = var.region
}

# Tiger Cloud service provisioning is SPLIT by lifecycle:
#   - EPHEMERAL dev/candidate services are created with the Tiger CLI
#     (`tiger service create`), not Tofu — spun up and torn down per run.
#   - PERMANENT (non-ephemeral) services like the RAG store ARE Tofu-managed via
#     the `timescale` provider (see rag.tf), so their lifecycle, VPC, and VPC
#     peering live in code/state like any other infrastructure.
# Tofu still manages all AWS resources (state bucket, CodeBuild runner, IAM,
# the AWS side of VPC peering). The runner reads Tiger credentials from AWS
# Secrets Manager (var.tiger_secret_arn) when it needs them.
#
# The timescale provider needs credentials at PLAN time (not just apply). They
# come from the environment — the human exports TF_VAR_ts_project_id /
# TF_VAR_ts_access_key / TF_VAR_ts_secret_key locally; values are NEVER
# hardcoded here.
provider "timescale" {
  project_id = var.ts_project_id
  access_key = var.ts_access_key
  secret_key = var.ts_secret_key
}

