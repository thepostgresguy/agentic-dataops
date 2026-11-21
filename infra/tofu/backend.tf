# OpenTofu backend configuration.
#
# PHASE 1 (now): LOCAL backend. There is intentionally NO active backend block
# here, so OpenTofu uses local state. This is required to create the S3 state
# bucket itself — the bucket cannot back the state that creates it.
#
# PHASE 2 (after the bucket exists): migrate state into S3.
#   1. Uncomment the block below (set the bucket name to match
#      var.state_bucket_name if you overrode the default).
#   2. Run:  tofu init -migrate-state
#      OpenTofu will offer to copy the existing local state into S3.
#
# NOTE: a backend block cannot use variables/interpolation — the bucket name
# must be a literal here. Keep it in sync with var.state_bucket_name.

terraform {
  backend "s3" {
    bucket  = "<your-state-bucket>"
    key     = "bootstrap/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
}
