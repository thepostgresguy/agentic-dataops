# Outputs from the Phase 1 bootstrap.

output "state_bucket_name" {
  description = "Name of the S3 bucket holding OpenTofu remote state."
  value       = aws_s3_bucket.tofu_state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the OpenTofu remote-state S3 bucket."
  value       = aws_s3_bucket.tofu_state.arn
}

output "region" {
  description = "AWS region the bucket was created in."
  value       = var.region
}
