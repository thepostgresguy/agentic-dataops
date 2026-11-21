#!/usr/bin/env bash
#
# Run `tofu` with the Tiger Cloud (Timescale) provider credentials fed from AWS
# Secrets Manager — NOT from a local .env or the command line.
#
# The `timescale` provider needs creds at PLAN time (not just apply), so this
# wrapper fetches the secret, exports the three TF_VAR_ts_* variables the
# provider block consumes, and execs tofu with whatever args you pass. The
# secret value is never echoed and never written to disk.
#
# The secret `agentic-dataops/tiger/dev` is a JSON object with keys:
#   project_id, access_id, secret_key
# Mapping to the Tofu provider variables (providers.tf):
#   access_id  -> TF_VAR_ts_access_key   (the provider's access_key / public key)
#   secret_key -> TF_VAR_ts_secret_key
#   project_id -> TF_VAR_ts_project_id
#
# AWS access itself comes from the ambient AWS credentials (the CodeBuild
# runner's IAM role in CI, which already has scoped GetSecretValue on this ARN;
# or your local AWS profile when run by hand). No AWS keys are stored anywhere.
#
# Usage (from infra/tofu/):
#   ./tofu-with-tiger-creds.sh plan -input=false -no-color
#   ./tofu-with-tiger-creds.sh apply -input=false
#   ./tofu-with-tiger-creds.sh validate
#
# Overridable via env:
#   TIGER_SECRET_ID  (default "agentic-dataops/tiger/dev")
#   AWS_REGION       (default "us-east-1")
set -euo pipefail

SECRET_ID="${TIGER_SECRET_ID:-agentic-dataops/tiger/dev}"
REGION="${AWS_REGION:-us-east-1}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required but not found on PATH" >&2
  exit 1
fi

echo "[tofu-creds] fetching Tiger provider credentials from Secrets Manager (${SECRET_ID} in ${REGION})" >&2
secret_json="$(aws secretsmanager get-secret-value \
  --secret-id "${SECRET_ID}" \
  --region "${REGION}" \
  --query SecretString \
  --output text)" || {
  echo "error: failed to fetch secret '${SECRET_ID}' from AWS Secrets Manager" >&2
  exit 1
}
[ -n "${secret_json}" ] || { echo "error: secret '${SECRET_ID}' is empty" >&2; exit 1; }

ts_project_id="$(printf '%s' "${secret_json}" | jq -r '.project_id // empty')"
ts_access_key="$(printf '%s' "${secret_json}" | jq -r '.access_id // empty')"
ts_secret_key="$(printf '%s' "${secret_json}" | jq -r '.secret_key // empty')"
unset secret_json

[ -n "${ts_project_id}" ] || { echo "error: secret '${SECRET_ID}' is missing 'project_id'" >&2; exit 1; }
[ -n "${ts_access_key}" ] || { echo "error: secret '${SECRET_ID}' is missing 'access_id'" >&2; exit 1; }
[ -n "${ts_secret_key}" ] || { echo "error: secret '${SECRET_ID}' is missing 'secret_key'" >&2; exit 1; }

export TF_VAR_ts_project_id="${ts_project_id}"
export TF_VAR_ts_access_key="${ts_access_key}"
export TF_VAR_ts_secret_key="${ts_secret_key}"

echo "[tofu-creds] credentials loaded for project ${ts_project_id}; running: tofu $*" >&2
exec tofu "$@"
