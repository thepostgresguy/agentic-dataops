# Dedicated, isolated Secrets Manager secret holding the Tiger Cloud dev-service
# credentials for this demo (charter: `agentic-dataops/tiger/dev`, us-east-1).
#
# Tofu creates the CONTAINER ONLY — no value. You populate the keys out-of-band
# so the Tiger credentials never touch Tofu code or state:
#
#   aws secretsmanager put-secret-value \
#     --secret-id agentic-dataops/tiger/dev \
#     --secret-string '{"project_id":"<project_id>","access_id":"<access_id>","secret_key":"<secret_key>"}' \
#     --region us-east-1
#
# The value is a JSON object with keys project_id / access_id / secret_key
# (shape documented here only — never set in Tofu). The runner reads this one
# secret via the scoped GetSecretValue grant in iam.tf.

resource "aws_secretsmanager_secret" "tiger_dev" {
  name        = "agentic-dataops/tiger/dev"
  description = "Tiger Cloud dev-service credentials (project_id/access_id/secret_key) for the agentic-dataops demo. Value populated out-of-band via AWS CLI; never stored in Tofu."

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "tiger-dev-credentials"
    ManagedBy = "opentofu"
  }
}

output "tiger_dev_secret_arn" {
  description = "ARN of the Tiger dev-credentials secret. Populate its value with the AWS CLI (see tiger_dev_secret.tf)."
  value       = aws_secretsmanager_secret.tiger_dev.arn
}
