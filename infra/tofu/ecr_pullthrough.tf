# ECR for the RAG-store Liquibase applier: the repo CI pushes the built image
# to, plus a Docker Hub pull-through cache so the Liquibase base image is pulled
# through our own ECR (not docker.io directly) and is not subject to Docker Hub
# anonymous rate limits.
#
# The Docker Hub credential lives in aws_secretsmanager_secret.dockerhub_pullthrough
# (ecr_pullthrough_secret.tf), name `ecr-pullthroughcache/dockerhub`, value
# populated out-of-band ({"username":...,"accessToken":...}).

# --- Pull-through cache rule: docker.io mirrored under the `docker-hub/` prefix ---
# The Dockerfile FROM is <registry>/docker-hub/liquibase/liquibase:5.0 — the
# first build seeds the cache (authenticated via the secret), later pulls are
# served from ECR.
resource "aws_ecr_pull_through_cache_rule" "dockerhub" {
  ecr_repository_prefix = "docker-hub"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = aws_secretsmanager_secret.dockerhub_pullthrough.arn
}

# --- ECR repo for the built rag-migrate applier image ---
# Mirrors ecr.tf / agent.tf: immutable tags, scan on push, expire untagged.
resource "aws_ecr_repository" "rag_migrate" {
  name                 = "agentic-dataops/rag-migrate"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "rag-migrate-image"
    ManagedBy = "opentofu"
  }
}

resource "aws_ecr_lifecycle_policy" "rag_migrate" {
  repository = aws_ecr_repository.rag_migrate.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images older than 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_rag_migrate_repository_url" {
  description = "ECR repository URL for the RAG-migrate (Liquibase applier) image."
  value       = aws_ecr_repository.rag_migrate.repository_url
}

# --- ECR repo for the RAG ingestion image ---
resource "aws_ecr_repository" "rag_ingest" {
  name                 = "agentic-dataops/rag-ingest"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "rag-ingest-image"
    ManagedBy = "opentofu"
  }
}

resource "aws_ecr_lifecycle_policy" "rag_ingest" {
  repository = aws_ecr_repository.rag_ingest.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images older than 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_rag_ingest_repository_url" {
  description = "ECR repository URL for the RAG ingestion image."
  value       = aws_ecr_repository.rag_ingest.repository_url
}
