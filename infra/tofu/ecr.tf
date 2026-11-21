# ECR repository for the app container image.
#
# ECS Fargate pulls the app image from here. (The AI agent will get its own
# repo later.) The image is built and pushed by CI (GitHub Actions on the
# CodeBuild runner) — not by hand.

resource "aws_ecr_repository" "app" {
  name                 = "agentic-dataops/app"
  image_tag_mutability = "IMMUTABLE" # each tag is write-once; no overwriting a deployed tag

  image_scanning_configuration {
    scan_on_push = true # free vulnerability scan on each push
  }

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "app-image"
    ManagedBy = "opentofu"
  }
}

# Expire old untagged images so the registry doesn't grow without bound.
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

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

output "ecr_app_repository_url" {
  description = "ECR repository URL for the app image (use for docker build/push and the ECS task definition)."
  value       = aws_ecr_repository.app.repository_url
}
