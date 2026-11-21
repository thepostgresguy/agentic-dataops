# Permanent APP Tiger Cloud service (the long-lived application database for
# devices/sensor_readings), created by Tofu via the timescale provider in the
# CURRENT project — same pattern as the RAG store (rag.tf), distinct service.
#
# This replaces the hand-created free instance and the out-of-band-populated
# app/database-url secret: Tofu creates the service AND writes its tsdbadmin DSN
# into the secret automatically on apply (no manual put-secret-value).
#
# NETWORKING: PRIVATE, VPC-attached — bound to the SAME Tiger VPC as the RAG
# service (timescale_vpcs.rag), which is already peered to the existing AWS VPC
# (var.rag_peer_vpc_id, vpc-0123456789abcdef1) with routes in place (rag.tf).
# Reusing that one Tiger VPC + peering avoids a second peering/CIDR/route set;
# Tiger allows multiple services in one Tiger VPC. So this service is reachable
# ONLY over the peering (no public endpoint), like RAG.
#
# REACHABILITY: this service is private (peering-only). The ECS app runs in the
# peer VPC's private subnets, so it reaches this service over the peering. The
# app schema is applied by Liquibase (`scripts/liquibase_app.sh update` in
# deploy.yml / app-migrate.yml) on the VPC-attached CodeBuild runner — Liquibase
# owns ALL migrations (app under infra/db/app, RAG under infra/db/rag). Prisma
# is the app's query client only, kept in sync with the changesets by hand.
#
# SIZING: lean default 0.5 CPU / 2 GB (var-driven, bump later) like RAG.
#
# Trade-off (accepted, same as RAG): the provider-generated tsdbadmin password
# lands in Tofu state (encrypted, versioned, public-access-blocked S3). Writing
# the DSN secret here does not widen that exposure.

resource "timescale_service" "app" {
  name        = "agentic-dataops-app"
  milli_cpu   = var.app_db_milli_cpu
  memory_gb   = var.app_db_memory_gb
  region_code = var.region
  vpc_id      = timescale_vpcs.rag.id
}

# Write the full DATABASE_URL (libpq DSN, what Prisma/the app expect) into the
# existing app secret automatically. "tsdb" is the default database on a Tiger
# service; sslmode=require (Tiger needs TLS).
resource "aws_secretsmanager_secret_version" "app_database_url" {
  secret_id = aws_secretsmanager_secret.app_database_url.id
  secret_string = format(
    "postgresql://%s:%s@%s:%s/tsdb?sslmode=require",
    timescale_service.app.username,
    timescale_service.app.password,
    timescale_service.app.hostname,
    timescale_service.app.port,
  )
}

output "app_service_host" {
  description = "Hostname of the permanent app Tiger service."
  value       = timescale_service.app.hostname
}

output "app_service_port" {
  description = "Port of the permanent app Tiger service."
  value       = timescale_service.app.port
}
