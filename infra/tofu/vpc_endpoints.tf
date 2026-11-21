# VPC endpoints (Option A) — give the private subnets a NAT-INDEPENDENT path to
# the AWS APIs the RAG-migrate task and the AgentCore agent need. Without these
# (or a NAT), a task on the private subnets cannot pull its image from ECR, read
# the DSN from Secrets Manager, write logs, or (for the agent) call Bedrock.
#
# Interface endpoints (one ENI per subnet, private DNS so the normal AWS SDK/CLI
# endpoints resolve to them): secretsmanager, ecr.api, ecr.dkr, logs, sts,
# bedrock-runtime. Gateway endpoint (free, route-table based): s3 — ECR image
# LAYERS are served from S3, so ecr.dkr + s3 are both required for image pulls.
#
# Cost note ($1000/30-day budget): interface endpoints bill ~$7.30/mo each
# (6 => ~$44/mo) + data processing; the S3 gateway endpoint is free. This is the
# deliberate trade for self-contained, NAT-independent egress (Option A). Reuses
# data.aws_vpc.rag_peer and data.aws_route_tables.rag_peer_all from rag.tf.

locals {
  interface_endpoint_services = [
    "com.amazonaws.${var.region}.secretsmanager",
    "com.amazonaws.${var.region}.ecr.api",
    "com.amazonaws.${var.region}.ecr.dkr",
    "com.amazonaws.${var.region}.logs",
    "com.amazonaws.${var.region}.sts",
    "com.amazonaws.${var.region}.bedrock-runtime",
  ]
}

# SG for the interface endpoints: allow 443 from within the VPC (the task/agent
# SGs egress 443; endpoint ENIs accept it from the VPC CIDR).
resource "aws_security_group" "vpce" {
  name        = "agentic-dataops-vpce"
  description = "Allow HTTPS (443) from within the VPC to the interface VPC endpoints."
  vpc_id      = var.rag_peer_vpc_id

  ingress {
    description = "HTTPS from within the VPC to the endpoint ENIs."
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.rag_peer.cidr_block]
  }

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

# Interface endpoints, on the private subnets, private DNS enabled so the
# standard service hostnames resolve to the endpoint inside the VPC.
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoint_services)

  vpc_id              = var.rag_peer_vpc_id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.agent_subnet_ids
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
    Service   = each.value
  }
}

# S3 gateway endpoint (free) — required for ECR image layer pulls. Associated
# with every route table in the VPC so any private subnet reaches S3 privately.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.rag_peer_vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.rag_peer_all.ids

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
    Service   = "com.amazonaws.${var.region}.s3"
  }
}
