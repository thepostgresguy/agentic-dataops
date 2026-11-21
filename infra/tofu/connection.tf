# Phase 2 — GitHub <-> AWS link via AWS CodeConnections.
#
# IMPORTANT (one-time manual step, cannot be fully codified):
# A CodeConnections connection created by OpenTofu/CLI/CloudFormation is created
# in PENDING status. You must AUTHORIZE it once in the AWS console
# (CodeConnections / Developer Tools > Settings > Connections >
# "Update pending connection") to complete the GitHub handshake and move it to
# AVAILABLE. Until then, the CodeBuild runner cannot reach the repo.
#
# This is the single part of the bootstrap that is not pure Tofu, by AWS design.

resource "aws_codeconnections_connection" "github" {
  name          = "agentic-dataops-github"
  provider_type = "GitHub"

  tags = {
    Project   = "agentic-dataops"
    ManagedBy = "opentofu"
  }
}

output "codeconnections_connection_arn" {
  description = "ARN of the GitHub CodeConnections connection. AUTHORIZE it in the console (it is created PENDING)."
  value       = aws_codeconnections_connection.github.arn
}

output "codeconnections_status_note" {
  description = "Reminder: the connection is PENDING until authorized in the AWS console."
  value       = "Authorize the connection in the AWS console (Developer Tools > Settings > Connections) to move it from PENDING to AVAILABLE."
}
