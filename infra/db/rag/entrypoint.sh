#!/usr/bin/env bash
#
# RAG-store Liquibase applier entrypoint (runs inside the one-shot ECS Fargate
# task, in-VPC, reaching the PRIVATE RAG endpoint over the peering).
#
# Responsibilities:
#   1. Fetch the agentic-dataops/tiger/rag secret (via the TASK role's
#      GetSecretValue) and parse host/port/username/password/dbname with jq.
#   2. Build the Liquibase JDBC connection (sslmode=require, currentSchema=public)
#      and export it as LIQUIBASE_COMMAND_* — never baked into the image, never
#      printed.
#   3. Dispatch the requested command. `update` ALWAYS tags the DB afterward with
#      the deployed image's git SHA, so a tag-based rollback point exists after
#      every deploy. Rollbacks are first-class: `rollback <tag>` (preferred) and
#      `rollback-count <n>`.
#
# Secret values are NEVER echoed and `set -x` is NEVER enabled.
set -euo pipefail

SECRET_ID="${RAG_SECRET_ID:-agentic-dataops/tiger/rag}"
REGION="${AWS_REGION:-us-east-1}"
# The tag applied on every successful `update`. Defaults to the deployed image's
# git SHA (set by the task definition via RAG_MIGRATE_TAG); falls back to a
# timestamp only if unset, so a tag always exists.
TAG="${RAG_MIGRATE_TAG:-$(date -u +%Y%m%d%H%M%S)}"

log()  { printf '[rag-migrate] %s\n' "$*" >&2; }
die()  { printf '[rag-migrate][ERROR] %s\n' "$*" >&2; exit 1; }

command -v aws >/dev/null 2>&1 || die "aws CLI not found in image"
command -v jq  >/dev/null 2>&1 || die "jq not found in image"

# --- 1. Fetch + parse the secret (values never printed) ---
log "fetching RAG credentials from Secrets Manager (${SECRET_ID} in ${REGION})"
SECRET_JSON="$(aws secretsmanager get-secret-value \
  --secret-id "${SECRET_ID}" \
  --region "${REGION}" \
  --query SecretString \
  --output text)" || die "failed to fetch secret ${SECRET_ID}"
[ -n "${SECRET_JSON}" ] || die "secret ${SECRET_ID} is empty"

host="$(printf '%s' "${SECRET_JSON}" | jq -r '.host // empty')"
port="$(printf '%s' "${SECRET_JSON}" | jq -r '.port // empty')"
username="$(printf '%s' "${SECRET_JSON}" | jq -r '.username // empty')"
password="$(printf '%s' "${SECRET_JSON}" | jq -r '.password // empty')"
dbname="$(printf '%s' "${SECRET_JSON}" | jq -r '.dbname // "tsdb"')"
unset SECRET_JSON

[ -n "${host}" ]     || die "secret ${SECRET_ID} missing field: host"
[ -n "${port}" ]     || die "secret ${SECRET_ID} missing field: port"
[ -n "${username}" ] || die "secret ${SECRET_ID} missing field: username"
[ -n "${password}" ] || die "secret ${SECRET_ID} missing field: password"

# --- 2. Build the Liquibase connection (TLS required; schema pinned to public) ---
export LIQUIBASE_COMMAND_URL="jdbc:postgresql://${host}:${port}/${dbname}?sslmode=require&currentSchema=public"
export LIQUIBASE_COMMAND_USERNAME="${username}"
export LIQUIBASE_COMMAND_PASSWORD="${password}"
# The changelog is MOUNTED (not baked) at /work from the git checkout. Run from
# there and reference the changelog by its plain relative name (Liquibase
# resolves relative paths from the working directory). RAG_CHANGELOG_DIR lets
# the mount point be overridden; default /work matches the workflow's -v mount.
CHANGELOG_DIR="${RAG_CHANGELOG_DIR:-/work}"
[ -f "${CHANGELOG_DIR}/changelog.xml" ] || die "changelog.xml not found in ${CHANGELOG_DIR} — is the git checkout mounted there?"
cd "${CHANGELOG_DIR}"
export LIQUIBASE_COMMAND_CHANGELOG_FILE="changelog.xml"
unset password

# --- 3. Dispatch ---
# $1 = command (default update); remaining args are command-specific.
CMD="${1:-update}"
shift || true

case "${CMD}" in
  update)
    log "running: liquibase update"
    liquibase update
    log "tagging database state: ${TAG}"
    liquibase tag "${TAG}"
    log "update + tag complete (tag=${TAG})"
    ;;
  rollback)
    # Preferred rollback path: roll back to a named tag.
    TARGET_TAG="${1:-}"
    [ -n "${TARGET_TAG}" ] || die "rollback requires a tag argument (e.g. rollback <git-sha>)"
    log "running: liquibase rollback ${TARGET_TAG}"
    liquibase rollback "${TARGET_TAG}"
    log "rollback to tag ${TARGET_TAG} complete"
    ;;
  rollback-count)
    N="${1:-}"
    [ -n "${N}" ] || die "rollback-count requires a count argument (e.g. rollback-count 1)"
    log "running: liquibase rollback-count ${N}"
    liquibase rollback-count "${N}"
    log "rollback-count ${N} complete"
    ;;
  status)
    log "running: liquibase status --verbose"
    liquibase status --verbose
    ;;
  validate)
    log "running: liquibase validate"
    liquibase validate
    ;;
  release-locks)
    # Only safe when no rag-migrate task is RUNNING (the invoke workflow checks).
    log "running: liquibase release-locks"
    liquibase release-locks
    ;;
  *)
    die "unknown command: ${CMD} (expected update|rollback|rollback-count|status|validate|release-locks)"
    ;;
esac
