#!/usr/bin/env bash
#
# Run Liquibase against the APP database (agentic-dataops-app), from the
# VPC-attached CodeBuild runner. Used by the app-migrate and deploy workflows.
#
# Reuses the RAG store's Liquibase image (agentic-dataops/rag-migrate: Liquibase
# 5 + PostgreSQL JDBC driver), bypassing its RAG-specific entrypoint. The app
# changelog is MOUNTED from the git checkout (infra/db/app -> /work), never
# baked into the image, so a new changeset is just a commit.
#
# Connection: the app DSN (a postgresql:// URL) is read from Secrets Manager via
# the runner's IAM role, converted to JDBC, and passed to the container as
# LIQUIBASE_COMMAND_* environment variables. Never printed, never on a command
# line.
#
# Usage: liquibase_app.sh <command> [arg]
#   update          apply pending changesets, then tag the DB ($LIQUIBASE_TAG,
#                   default: current git SHA)
#   update-sql      print the SQL `update` would run (read-only preview)
#   status          list pending changesets (read-only)
#   history         list applied changesets (read-only)
#   validate        validate the changelog against the DB (read-only)
#   baseline-sync   mark ONLY the `baseline`-labelled changeset as run without
#                   executing it (for a database whose tables already exist)
#   rollback <tag>  roll back to a tag (preferred rollback)
#   rollback-count <n>
#   release-locks   clear a stuck Liquibase lock
#
# Env: AWS_REGION (default us-east-1), APP_DB_SECRET_ID (default
#      agentic-dataops/app/database-url), LIQUIBASE_IMAGE_REPO (default
#      agentic-dataops/rag-migrate), LIQUIBASE_TAG.
#      Optional overrides (used by migration-test to build an EPHEMERAL schema;
#      the defaults above are unchanged for app-migrate / deploy):
#        LIQUIBASE_TARGET_DSN     postgresql:// DSN to migrate INSTEAD of the app
#                                 secret (e.g. an ephemeral Tiger service).
#        LIQUIBASE_CHANGELOG_DIR  directory holding changelog.xml + changesets/
#                                 (e.g. a checkout of main), instead of
#                                 infra/db/app in this checkout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
SECRET_ID="${APP_DB_SECRET_ID:-agentic-dataops/app/database-url}"
IMAGE_REPO="${LIQUIBASE_IMAGE_REPO:-agentic-dataops/rag-migrate}"
CHANGELOG_DIR="${LIQUIBASE_CHANGELOG_DIR:-${ROOT}/infra/db/app}"

log() { printf '[app-migrate] %s\n' "$*" >&2; }
die() { printf '::error::[app-migrate] %s\n' "$*" >&2; exit 1; }

CMD="${1:?usage: liquibase_app.sh <command> [arg]}"
ARG="${2:-}"

case "${CMD}" in
  update|update-sql|status|history|validate|baseline-sync|release-locks) ;;
  rollback)       [ -n "${ARG}" ] || die "rollback requires a tag" ;;
  rollback-count) printf '%s' "${ARG}" | grep -qE '^[1-9][0-9]*$' || die "rollback-count requires a positive integer" ;;
  *) die "unknown command '${CMD}'" ;;
esac
[ -f "${CHANGELOG_DIR}/changelog.xml" ] || die "missing ${CHANGELOG_DIR}/changelog.xml"

# --- Connection (secret -> JDBC; values never printed) ---
if [ -n "${LIQUIBASE_TARGET_DSN:-}" ]; then
  log "using the explicit LIQUIBASE_TARGET_DSN (not the app secret)"
  DSN="${LIQUIBASE_TARGET_DSN}"
  unset LIQUIBASE_TARGET_DSN
else
  log "reading app DSN from Secrets Manager (${SECRET_ID})"
  DSN="$(aws secretsmanager get-secret-value --secret-id "${SECRET_ID}" \
    --region "${REGION}" --query SecretString --output text)" || die "cannot read ${SECRET_ID}"
  [ -n "${DSN}" ] || die "secret ${SECRET_ID} is empty"
fi

# Prints three lines: jdbc url, username, password.
PARSED="$(DSN="${DSN}" python3 -I -c '
import os, sys, urllib.parse as u
p = u.urlsplit(os.environ["DSN"])
if p.scheme not in ("postgres", "postgresql") or not p.hostname or not p.username:
    sys.exit("DSN must be postgresql://user:password@host:port/db")
db = (p.path or "/tsdb").lstrip("/") or "tsdb"
print(f"jdbc:postgresql://{p.hostname}:{p.port or 5432}/{db}?sslmode=require&currentSchema=public")
print(u.unquote(p.username))
print(u.unquote(p.password or ""))
')" || die "app DSN is not a valid postgresql:// URL"
unset DSN
LIQUIBASE_COMMAND_URL="$(printf '%s\n' "${PARSED}" | sed -n 1p)"
LIQUIBASE_COMMAND_USERNAME="$(printf '%s\n' "${PARSED}" | sed -n 2p)"
LIQUIBASE_COMMAND_PASSWORD="$(printf '%s\n' "${PARSED}" | sed -n 3p)"
unset PARSED
[ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::${LIQUIBASE_COMMAND_PASSWORD}"
export LIQUIBASE_COMMAND_URL LIQUIBASE_COMMAND_USERNAME LIQUIBASE_COMMAND_PASSWORD

# --- Image (latest pushed Liquibase runtime) ---
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}" >/dev/null
IMAGE_TAG="$(aws ecr describe-images --repository-name "${IMAGE_REPO}" --region "${REGION}" \
  --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' --output text)"
[ -n "${IMAGE_TAG}" ] && [ "${IMAGE_TAG}" != "None" ] || die "no image in ${IMAGE_REPO}"
IMAGE="${REGISTRY}/${IMAGE_REPO}:${IMAGE_TAG}"
docker pull -q "${IMAGE}" >/dev/null

lb() {
  # --network host: the runner is VPC-attached and reaches the private app DB
  # over the peering; the container shares that network.
  docker run --rm --network host \
    -e LIQUIBASE_COMMAND_URL -e LIQUIBASE_COMMAND_USERNAME -e LIQUIBASE_COMMAND_PASSWORD \
    -e LIQUIBASE_COMMAND_CHANGELOG_FILE=changelog.xml \
    -e LIQUIBASE_SEARCH_PATH=/work \
    -v "${CHANGELOG_DIR}:/work:ro" -w /work \
    --entrypoint liquibase "${IMAGE}" "$@"
}

# --- Dispatch ---
case "${CMD}" in
  update)
    TAG="${LIQUIBASE_TAG:-$(git -C "${ROOT}" rev-parse HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)}"
    log "update (then tag ${TAG})"
    lb update
    lb tag --tag="${TAG}"
    log "update + tag complete (tag=${TAG})"
    ;;
  update-sql)     lb update-sql ;;
  status)         lb status --verbose ;;
  history)        lb history ;;
  validate)       lb validate ;;
  baseline-sync)
    log "marking the baseline-labelled changeset as run (no SQL executed)"
    lb changelog-sync --label-filter=baseline
    lb history
    ;;
  rollback)       lb rollback --tag="${ARG}" ;;
  rollback-count) lb rollback-count --count="${ARG}" ;;
  release-locks)  lb release-locks ;;
esac
log "${CMD} succeeded"
