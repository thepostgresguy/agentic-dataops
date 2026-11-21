# Input variables for the Phase 1 bootstrap (S3 state bucket).

variable "region" {
  description = "AWS region for all resources. Charter default: us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = <<-EOT
    Name of the dedicated S3 bucket that will hold the OpenTofu remote state for
    this project. S3 bucket names are GLOBALLY unique across all AWS accounts;
    the default is a placeholder and is not a valid bucket name: set your own
    (e.g. "<project>-tofu-state-<account-id>") via -var or a *.tfvars file, and
    use the same name in backend.tf.
  EOT
  type        = string
  default     = "<your-state-bucket>"
}

# --- Phase 2: CodeBuild GitHub Actions runner ---

variable "github_owner" {
  description = "GitHub org/user that owns the repo the runner serves."
  type        = string
  default     = "thepostgresguy"
}

variable "github_repo" {
  description = "GitHub repository name the runner serves."
  type        = string
  default     = "agentic-dataops"
}

variable "codebuild_compute_type" {
  description = "CodeBuild compute size for the runner."
  type        = string
  default     = "BUILD_GENERAL1_SMALL"
}

variable "codebuild_image" {
  description = "CodeBuild build image (pinned). Amazon Linux standard image."
  type        = string
  # Pinned known-good standard image; confirm the latest aws/codebuild image
  # tag you want before apply.
  default = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
}

variable "tiger_secret_arn" {
  description = <<-EOT
    ARN of the dedicated `agentic-dataops/tiger/dev` Tiger Cloud credentials
    secret created by tiger_dev_secret.tf. This is a NAME-BASED ARN (no random
    suffix): the live secret ARN has a trailing random 6-char suffix that is not
    known until apply. If the scoped IAM policy in iam.tf needs the exact ARN,
    override this var with the full ARN including the suffix.
  EOT
  type        = string
  default     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:agentic-dataops/tiger/dev"
}

# Note: the Tiger DEV SERVICE itself is created with the Tiger CLI
# (`tiger service create --cpu shared --memory shared`), not Tofu. Only the
# secret ARN above is referenced here (by iam.tf, for the runner's read
# permission).

# --- Phase 4: ECS Fargate + ALB + ACM deploy of the app ---

variable "app_domain" {
  description = "Public domain the app is served at (ACM cert + app CNAME target the ALB)."
  type        = string
  default     = "overflow.thepostgresguy.com"
}

variable "app_image_tag" {
  description = <<-EOT
    ECR image tag to deploy (the app container). For the demo this is set
    manually to the git SHA that was pushed (e.g. -var app_image_tag=<sha>).
    The deploy workflow passes it in. Default pinned to a known-pushed SHA
    (NOT "latest", which never exists in the immutable repo).
  EOT
  type        = string
  default     = "d27a7a47b78861375fdc8fa553013d463dbe361a"
}

variable "app_container_port" {
  description = "Port the app's Fastify server listens on (ALB target)."
  type        = number
  default     = 8080
}

variable "app_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU — smallest, cheapest)."
  type        = number
  default     = 256
}

variable "app_memory" {
  description = "Fargate task memory MiB (512 — smallest for 256 CPU)."
  type        = number
  default     = 512
}

variable "app_desired_count" {
  description = "Number of running app tasks. 1 for a lean demo."
  type        = number
  default     = 1
}

variable "app_db_secret_arn" {
  description = <<-EOT
    ARN of the Secrets Manager secret holding the app's DATABASE_URL
    (agentic-dataops/app/database-url). The ECS task reads DATABASE_URL from it.
    Defaults to the known name-based ARN prefix; override if the random suffix
    differs.
  EOT
  type        = string
  default     = ""
}

# --- Phase 5: AgentCore agent (the DB-consultant agent) ---

variable "agent_image_tag" {
  description = <<-EOT
    OPTIONAL override for the agent image tag (git SHA). Leave EMPTY (default)
    for fully-automatic deploys: agent.tf resolves the NEWEST pushed image from
    ECR via a data source, so `tofu apply` always deploys the latest agent build
    with NO manual -var and NO hand-edited SHA. Set a specific SHA here only to
    pin/roll back to a particular image.
  EOT
  type        = string
  default     = ""
}

variable "agent_image_auto" {
  description = <<-EOT
    When true (default) and agent_image_tag is empty, resolve the newest agent
    image from ECR automatically. Set to FALSE only for a first-ever apply
    BEFORE any agent image exists (an empty repo would make the lookup fail);
    flip back to true once the first image is pushed.
  EOT
  type        = bool
  default     = true
}

variable "app_public_subnet_ids" {
  description = <<-EOT
    PUBLIC (IGW-routed) subnet ids in the peer VPC (var.rag_peer_vpc_id) for the
    public ALB — multi-AZ. The app stack lives in this VPC so the tasks (in the
    private subnets) can reach the private app DB over the peering.
  EOT
  type        = list(string)
  default     = ["subnet-0123456789abcdef3", "subnet-0123456789abcdef4"]
}

# NOTE: the app TASKS use var.agent_subnet_ids (the PRIVATE, NAT-routed subnets
# in the same VPC that carry the peering route to the app/RAG Tiger CIDR).

variable "app_db_milli_cpu" {
  description = "Permanent app Tiger service CPU (milli). Default 500 = 0.5 CPU (smallest), bump later."
  type        = number
  default     = 500
}

variable "app_db_memory_gb" {
  description = "Permanent app Tiger service memory (GB). 2 pairs with 500m CPU."
  type        = number
  default     = 2
}

variable "rag_migrate_image_tag" {
  description = <<-EOT
    ECR image tag (git SHA) for the RAG-store Liquibase applier image. The
    rag-migrate ECS task definition is created only when this is non-empty (set
    it to the SHA the rag-migrate-image workflow pushed). Also passed to the
    container as RAG_MIGRATE_TAG so a successful `update` tags the DB with it.
    Empty = skip the task definition. Default pinned to a pushed SHA (NOT
    "latest", which never exists in the immutable repo); the rag-migrate-image
    workflow pushes new SHAs and this is bumped to deploy a newer applier.
  EOT
  type        = string
  default     = "c13d007abedd3b995385c725fd476a3fa7ce4c79"
}

variable "agent_subnet_ids" {
  description = <<-EOT
    PRIVATE (NAT-routed) subnet ids in the peer VPC (var.rag_peer_vpc_id) to
    attach the VPC-mode AgentCore runtime to. These must carry the peering route
    to the Tiger RAG CIDR (so the agent reaches the private store) AND default-
    route via a NAT gateway (so the agent reaches AWS APIs over the SG's 443
    egress). Defaulted to the two NAT-routed private subnets confirmed in
    vpc-0123456789abcdef1; do NOT include the VPC's public (IGW-routed) subnets.
  EOT
  type        = list(string)
  default     = ["subnet-0123456789abcdef1", "subnet-0123456789abcdef2"]
}

variable "bedrock_model_id" {
  description = <<-EOT
    Bedrock model id the agent calls (default Amazon Nova Pro). Passed to the
    agent as an env var. Confirm the exact inference-profile/model id is enabled
    in us-east-1 before apply.
  EOT
  type        = string
  default     = "amazon.nova-pro-v1:0"
}

# --- Permanent RAG store (Tiger Cloud service via the timescale provider) ---

variable "ts_project_id" {
  description = <<-EOT
    Tiger Cloud project id the timescale provider operates in. Needed at PLAN
    time. Set via TF_VAR_ts_project_id in the environment (a project id is not a
    secret, so no default here forces an explicit, intentional value).
  EOT
  type        = string
  default     = ""
}

variable "ts_access_key" {
  description = <<-EOT
    Tiger Cloud access key for the timescale provider. Needed at PLAN time.
    Set via TF_VAR_ts_access_key in the environment; NEVER hardcode or commit.
  EOT
  type        = string
  sensitive   = true
  # No default — must be supplied explicitly via TF_VAR_ts_access_key.
}

variable "ts_secret_key" {
  description = <<-EOT
    Tiger Cloud secret key for the timescale provider. Needed at PLAN time.
    Set via TF_VAR_ts_secret_key in the environment; NEVER hardcode or commit.
  EOT
  type        = string
  sensitive   = true
  # No default — must be supplied explicitly via TF_VAR_ts_secret_key.
}

variable "rag_milli_cpu" {
  description = <<-EOT
    RAG service CPU in milli-CPU (500 = 0.5 CPU — the lean default; may be
    raised later). Must pair with rag_memory_gb per Tiger's supported sizes.
  EOT
  type        = number
  default     = 500

  validation {
    condition     = contains([500, 1000, 2000, 4000, 8000, 16000, 32000], var.rag_milli_cpu)
    error_message = "rag_milli_cpu must be one of the supported Tiger sizes: 500, 1000, 2000, 4000, 8000, 16000, 32000."
  }
}

variable "rag_memory_gb" {
  description = <<-EOT
    RAG service memory in GB. Must pair with rag_milli_cpu per Tiger's supported
    CPU/memory pairs (500/2, 1000/4, 2000/8, 4000/16, 8000/32, 16000/64,
    32000/128).
  EOT
  type        = number
  default     = 2

  validation {
    condition     = contains([2, 4, 8, 16, 32, 64, 128], var.rag_memory_gb)
    error_message = "rag_memory_gb must be one of the supported Tiger sizes: 2, 4, 8, 16, 32, 64, 128."
  }
}

variable "rag_peer_vpc_id" {
  description = "Existing AWS VPC id to VPC-peer the RAG Tiger service with (private-only reachability)."
  type        = string
  default     = "vpc-0123456789abcdef1"
}

variable "rag_tiger_cidr" {
  description = <<-EOT
    CIDR for the Tiger-side VPC that backs the RAG service. Hardcoded to a
    non-overlapping range per human decision (the peer VPC's CIDR is looked up
    automatically; this one is chosen not to overlap it).
  EOT
  type        = string
  default     = "10.42.0.0/24"
}
