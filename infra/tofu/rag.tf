# Permanent, PRIVATE RAG store — a long-lived Tiger Cloud Postgres service used
# as the retrieval-augmented-generation (RAG) vector store for the AI agent.
#
# Unlike the ephemeral dev/candidate services (Tiger CLI, torn down per run),
# this service is PERMANENT and therefore Tofu-managed via the `timescale`
# provider (see providers.tf). It is sized lean at 0.5 CPU / 2 GB by default
# (var.rag_milli_cpu / var.rag_memory_gb) and may be scaled later.
#
# PRIVATE-ONLY reachability: the service is bound to its own Tiger-side VPC
# (timescale_vpcs.rag via vpc_id) and reached through VPC peering to the
# EXISTING AWS VPC (var.rag_peer_vpc_id) — no public endpoint. The AWS side
# auto-accepts the peering and a route is added to the peer VPC's MAIN route
# table so it can reach the Tiger CIDR.
#
# pgvectorscale: the timescale provider has NO extension attribute, so the
# pgvectorscale extension that makes this a vector store is enabled by a
# SEPARATE, coded post-create step (e.g. a workflow-invoked SQL step running
# `CREATE EXTENSION vectorscale CASCADE;` against this service). That compute is
# a documented TODO and is deliberately NOT implemented here — this file only
# provisions the service, its VPC, and the peering.

# Existing AWS VPC to peer with — looked up so its CIDR is read automatically
# (not hardcoded) and used for the Tiger -> AWS route advertisement.
data "aws_vpc" "rag_peer" {
  id = var.rag_peer_vpc_id
}

# This account id — used as the peer_account_id Tiger peers back to.
data "aws_caller_identity" "current" {}

# ALL route tables in the peer VPC. The peer VPC's subnets use custom (non-main)
# route tables, and the main table may carry no subnets — so a route added only
# to the main table does not make the service reachable from the subnets (hosts,
# VPN sessions, in-VPC compute). We enumerate every route table in the VPC and
# add the Tiger-CIDR route to each, so every subnet (whichever table it is
# associated with) can reach the RAG service over the peering.
data "aws_route_tables" "rag_peer_all" {
  vpc_id = var.rag_peer_vpc_id
}

# Tiger-side VPC backing the RAG service (private network for peering).
resource "timescale_vpcs" "rag" {
  cidr        = var.rag_tiger_cidr
  region_code = var.region
  name        = "agentic-dataops-rag"
}

# The permanent RAG Postgres service, bound to the Tiger VPC above.
resource "timescale_service" "rag" {
  name        = "agentic-dataops-rag"
  milli_cpu   = var.rag_milli_cpu
  memory_gb   = var.rag_memory_gb
  region_code = var.region
  vpc_id      = timescale_vpcs.rag.id
}

# Tiger -> AWS VPC peering request (Tiger initiates; AWS accepts below).
resource "timescale_peering_connection" "rag" {
  peer_account_id  = data.aws_caller_identity.current.account_id
  peer_region_code = var.region
  peer_vpc_id      = var.rag_peer_vpc_id
  peer_cidr_blocks = [data.aws_vpc.rag_peer.cidr_block]
  timescale_vpc_id = timescale_vpcs.rag.id
}

# AWS side accepts the peering Tiger provisioned.
resource "aws_vpc_peering_connection_accepter" "rag" {
  vpc_peering_connection_id = timescale_peering_connection.rag.accepter_provisioned_id
  auto_accept               = true

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "rag-vpc-peering"
    ManagedBy = "opentofu"
  }

  depends_on = [timescale_peering_connection.rag]
}

# Route to the Tiger CIDR in EVERY route table of the peer VPC, so hosts in any
# subnet (plus VPN sessions and in-VPC compute) can reach the RAG service
# privately over the peering — not just whatever is on the main table. One
# aws_route per route table, keyed by route-table id so adds/removes are stable.
resource "aws_route" "rag_to_tiger" {
  for_each = toset(data.aws_route_tables.rag_peer_all.ids)

  route_table_id            = each.value
  destination_cidr_block    = var.rag_tiger_cidr
  vpc_peering_connection_id = timescale_peering_connection.rag.accepter_provisioned_id
}

# --- tsdbadmin credentials secret (populated automatically on apply) ---
#
# The timescale_service resource exposes the service's tsdbadmin credentials as
# read-only attributes (hostname / port / username / password). Rather than a
# container-only secret populated out-of-band (the tiger/dev + app DB pattern,
# used because THOSE values originate outside Tofu), here the values are
# PRODUCED by Tofu, so we write them straight into Secrets Manager on apply —
# no manual populate step.
#
# Trade-off (accepted): the provider-generated password lands in Tofu state. It
# already does, as a computed attribute of timescale_service, independent of
# this secret — writing it here does not widen exposure. State lives in the
# encrypted, versioned, public-access-blocked S3 bucket (backend.tf / s3.tf),
# the same trust level as the app DB password and the Tiger creds that already
# flow through state.

resource "aws_secretsmanager_secret" "rag_tsdbadmin" {
  name        = "agentic-dataops/tiger/rag"
  description = "tsdbadmin credentials + DSN for the permanent private RAG Tiger service (agentic-dataops-rag). Populated automatically from the timescale_service outputs on apply."

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "rag-tsdbadmin-credentials"
    ManagedBy = "opentofu"
  }
}

resource "aws_secretsmanager_secret_version" "rag_tsdbadmin" {
  secret_id = aws_secretsmanager_secret.rag_tsdbadmin.id

  # JSON with the individual fields plus a ready-to-use DATABASE_URL DSN. The
  # DSN targets the PRIVATE hostname (reachable only via the VPC peering) and
  # requires TLS. "tsdb" is the default database on a Tiger service.
  secret_string = jsonencode({
    host     = timescale_service.rag.hostname
    port     = timescale_service.rag.port
    username = timescale_service.rag.username
    password = timescale_service.rag.password
    dbname   = "tsdb"
    DATABASE_URL = format(
      "postgresql://%s:%s@%s:%s/tsdb?sslmode=require",
      timescale_service.rag.username,
      timescale_service.rag.password,
      timescale_service.rag.hostname,
      timescale_service.rag.port,
    )
  })
}

# --- Outputs for the RAG store ---

output "rag_service_host" {
  description = "Hostname of the permanent RAG Tiger service (private, reached via VPC peering)."
  value       = timescale_service.rag.hostname
}

output "rag_service_port" {
  description = "Port of the permanent RAG Tiger service."
  value       = timescale_service.rag.port
}

output "rag_peering_connection_id" {
  description = "AWS VPC peering connection id (pcx-...) for the RAG store peering."
  value       = timescale_peering_connection.rag.accepter_provisioned_id
}

output "rag_tiger_vpc_id" {
  description = "Tiger-side VPC id backing the RAG service."
  value       = timescale_vpcs.rag.id
}

output "rag_tsdbadmin_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the RAG service tsdbadmin credentials + DATABASE_URL (populated automatically on apply)."
  value       = aws_secretsmanager_secret.rag_tsdbadmin.arn
}
