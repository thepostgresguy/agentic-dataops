# ECS Fargate cluster + service running the app container behind the ALB.
#
# Lean demo: single small task (256 CPU / 512 MiB) in public subnets with a
# public IP (no NAT). The task reads DATABASE_URL from Secrets Manager.

locals {
  # Resolve the app DB secret ARN: use the explicit var if given, else the
  # secret created by app_db_secret.tf.
  app_db_secret_arn = var.app_db_secret_arn != "" ? var.app_db_secret_arn : aws_secretsmanager_secret.app_database_url.arn

  ecr_image = "${aws_ecr_repository.app.repository_url}:${var.app_image_tag}"
}

resource "aws_ecs_cluster" "app" {
  name = "agentic-dataops"
  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/agentic-dataops-app"
  retention_in_days = 14
  tags              = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

# --- Task execution role (pull image, write logs, read the DB secret) ---
resource "aws_iam_role" "ecs_execution" {
  name = "agentic-dataops-ecs-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the execution role to read the DB secret (for secret injection).
resource "aws_iam_role_policy" "ecs_execution_secret" {
  name = "read-app-db-secret"
  role = aws_iam_role.ecs_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = local.app_db_secret_arn
    }]
  })
}

# --- Task role (the app's own runtime identity; minimal for now) ---
resource "aws_iam_role" "ecs_task" {
  name = "agentic-dataops-ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

# --- Task definition ---
resource "aws_ecs_task_definition" "app" {
  family                   = "agentic-dataops-app"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.app_cpu)
  memory                   = tostring(var.app_memory)
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name      = "app"
    image     = local.ecr_image
    essential = true
    portMappings = [{
      containerPort = var.app_container_port
      protocol      = "tcp"
    }]
    # DATABASE_URL injected from Secrets Manager (not plaintext).
    secrets = [{
      name      = "DATABASE_URL"
      valueFrom = local.app_db_secret_arn
    }]
    environment = [{
      name  = "PORT"
      value = tostring(var.app_container_port)
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.app.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "app"
      }
    }
  }])

  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}

# --- Service ---
resource "aws_ecs_service" "app" {
  name            = "agentic-dataops-app"
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.app_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    # App tasks run in the peer VPC's PRIVATE subnets (NAT-routed, carrying the
    # peering route to the app Tiger CIDR), so the app reaches its private DB
    # over the peering. No public IP; the public ALB (in this VPC's public
    # subnets) forwards to the task IPs. NAT covers image pulls + secret reads.
    subnets          = var.agent_subnet_ids
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "app"
    container_port   = var.app_container_port
  }

  # The HTTPS listener (and thus the validated cert) must exist first.
  depends_on = [aws_lb_listener.https]

  tags = { Project = "agentic-dataops", ManagedBy = "opentofu" }
}
