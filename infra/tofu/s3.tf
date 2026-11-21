# Dedicated S3 bucket for this project's OpenTofu remote state.
#
# This is the ONLY resource in the Phase 1 bootstrap. It is created with local
# state (see providers.tf / backend.tf); once it exists you migrate the state
# into it.
#
# State-bucket hygiene: versioning ON (recover prior state / avoid corruption),
# encryption ON, all public access blocked. These matter because the bucket
# holds infrastructure state.

resource "aws_s3_bucket" "tofu_state" {
  bucket = var.state_bucket_name

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "opentofu-remote-state"
    ManagedBy = "opentofu"
  }
}

# Keep historical versions of the state file.
resource "aws_s3_bucket_versioning" "tofu_state" {
  bucket = aws_s3_bucket.tofu_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypt state at rest (SSE-S3 / AES256 by default).
resource "aws_s3_bucket_server_side_encryption_configuration" "tofu_state" {
  bucket = aws_s3_bucket.tofu_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access to the state bucket.
resource "aws_s3_bucket_public_access_block" "tofu_state" {
  bucket                  = aws_s3_bucket.tofu_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
