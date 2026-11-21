#!/usr/bin/env bash
# Shared helpers for guardrail scripts. Sourced, not executed.
set -euo pipefail

log()  { printf '\033[1;34m[guardrail]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# require_env NAME - fail if an env var is unset/empty
require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    fail "required environment variable '${name}' is not set"
  fi
}

# psql_do <dsn> <sql> - run SQL, fail loudly. Values are passed via args; the
# SQL is fixed text from these scripts (no user interpolation).
psql_do() {
  local dsn="$1" sql="$2"
  psql "${dsn}" -v ON_ERROR_STOP=1 -qAt -c "${sql}"
}

# tiger_login_from_secret - authenticate the Tiger CLI non-interactively using
# credentials stored ONLY in AWS Secrets Manager (never in GitHub). Reads the
# secret id from TIGER_SECRET_ID (default "agentic-dataops/tiger/dev") in region
# AWS_REGION (default "us-east-1"). The secret value is a JSON object with keys
# project_id, access_id, secret_key. Mapping:
#   access_id  -> TIGER_PUBLIC_KEY
#   secret_key -> TIGER_SECRET_KEY
#   project_id -> TIGER_PROJECT_ID (exported so later subcommands target it)
# Secret values are never echoed; only the non-sensitive project id is logged.
# Idempotent: safe to call more than once.
tiger_login_from_secret() {
  local secret_id="${TIGER_SECRET_ID:-agentic-dataops/tiger/dev}"
  local region="${AWS_REGION:-us-east-1}"
  local secret_json project_id access_id secret_key

  log "fetching Tiger credentials from AWS Secrets Manager (${secret_id} in ${region})"
  secret_json="$(aws secretsmanager get-secret-value \
    --secret-id "${secret_id}" \
    --region "${region}" \
    --query SecretString \
    --output text)" || fail "failed to fetch secret '${secret_id}' from AWS Secrets Manager"
  [[ -n "${secret_json}" ]] || fail "secret '${secret_id}' returned an empty value"

  project_id="$(jq -r '.project_id // empty' <<<"${secret_json}")"
  access_id="$(jq -r '.access_id // empty' <<<"${secret_json}")"
  secret_key="$(jq -r '.secret_key // empty' <<<"${secret_json}")"
  [[ -n "${project_id}" ]] || fail "secret '${secret_id}' is missing 'project_id'"
  [[ -n "${access_id}" ]]  || fail "secret '${secret_id}' is missing 'access_id'"
  [[ -n "${secret_key}" ]] || fail "secret '${secret_id}' is missing 'secret_key'"

  export TIGER_PUBLIC_KEY="${access_id}"
  export TIGER_SECRET_KEY="${secret_key}"
  export TIGER_PROJECT_ID="${project_id}"

  log "authenticating Tiger CLI to project ${project_id}"
  tiger auth login || fail "tiger auth login failed"
  ok "Tiger CLI authenticated"
}
