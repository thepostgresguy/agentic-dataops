# Docker Hub credential secret for the ECR pull-through cache.
#
# Tofu creates the CONTAINER ONLY — no value. You populate it out-of-band so
# the Docker Hub access token never touches Tofu code or state:
#
#   set -a; source .env; set +a   # loads DOCKER_TOKEN (and your Docker Hub username)
#   aws secretsmanager put-secret-value \
#     --secret-id ecr-pullthroughcache/dockerhub \
#     --secret-string "{\"username\":\"<dockerhub-username>\",\"accessToken\":\"${DOCKER_TOKEN}\"}" \
#     --region us-east-1
#
# ECR pull-through cache REQUIRES:
#   - the secret NAME to start with the literal prefix `ecr-pullthroughcache/`
#   - the value to be JSON: {"username":"<user>","accessToken":"<token>"}
#     (keys exactly `username` and `accessToken`).
# Use a Docker Hub ACCESS TOKEN (hub.docker.com -> Account Settings -> Security),
# not your account password. The token is never committed; .env is gitignored.

resource "aws_secretsmanager_secret" "dockerhub_pullthrough" {
  name        = "ecr-pullthroughcache/dockerhub"
  description = "Docker Hub credentials for the ECR pull-through cache (agentic-dataops). Value populated out-of-band via AWS CLI; never stored in Tofu."

  tags = {
    Project   = "agentic-dataops"
    Purpose   = "ecr-pullthrough-dockerhub"
    ManagedBy = "opentofu"
  }
}

output "dockerhub_pullthrough_secret_arn" {
  description = "ARN of the Docker Hub pull-through-cache credential secret. Populate its value with the AWS CLI (see this file's header)."
  value       = aws_secretsmanager_secret.dockerhub_pullthrough.arn
}
