#!/usr/bin/env bash
#
# Tear down the ephemeral dev service. Idempotent, and it FAILS LOUDLY if the
# service still exists afterwards, so a leaked (billed) service is never
# reported as cleaned up. Runs in CI as an `if: always()` cleanup step.
#
# The target can be the service ID or its NAME (the Tiger CLI accepts either).
# The workflow falls back to the per-run name when provisioning failed before an
# id was published, so a half-created service is still removed.
#
# Authenticates the Tiger CLI like provision_dev_service.sh: the secret
# `agentic-dataops/tiger/dev` from AWS Secrets Manager (runner IAM role) and
# `tiger auth login`. No secrets in GitHub.
#
# Outcome:
#   - delete succeeds                              -> exit 0
#   - delete fails but the service is NOT listed   -> exit 0 (already gone)
#   - delete fails and the service IS still listed -> exit 1 (leak, loud)
#
# Usage: teardown_dev_service.sh <service_id_or_name>
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

TARGET="${1:?usage: teardown_dev_service.sh <service_id_or_name>}"

tiger_login_from_secret

log "deleting dev service ${TARGET}"
# `tiger service delete <name-or-id>` takes the service POSITIONALLY and must be
# given explicitly; --confirm skips the interactive prompt. Output is NOT hidden
# so a failure is visible in the log.
if tiger service delete "${TARGET}" --confirm; then
  ok "teardown complete (deleted ${TARGET})"
  exit 0
fi

log "delete returned non-zero; checking whether ${TARGET} still exists"
LIST_JSON="$(tiger service list --output json)" || fail "could not list services to verify teardown of ${TARGET}"
# The list shape can vary by CLI version, so look for the id or name anywhere in
# the JSON rather than assuming field names.
if jq -e --arg t "${TARGET}" '[.. | strings] | index($t) != null' <<<"${LIST_JSON}" >/dev/null; then
  fail "service ${TARGET} STILL EXISTS after a failed delete: delete it manually in Tiger Cloud to stop billing"
fi

ok "teardown complete (${TARGET} is not present, nothing to delete)"
