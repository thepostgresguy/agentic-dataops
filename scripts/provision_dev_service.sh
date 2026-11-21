#!/usr/bin/env bash
#
# Provision an isolated, ephemeral Tiger Cloud dev service and print its DSN.
#
# Fully automated: uses Tiger CLI non-interactively. Authenticates the Tiger CLI
# by fetching the secret `agentic-dataops/tiger/dev` from AWS Secrets Manager
# (read at runtime via the CodeBuild runner's scoped IAM role) and running
# `tiger auth login` — no secrets are stored in GitHub. The service is named
# per-run so it is disposable and torn down by teardown_dev_service.sh.
#
# Emits the DSN on stdout (last line) and writes it to $GITHUB_OUTPUT as dsn=...
# when running in Actions.
#
# Usage: provision_dev_service.sh <service_name> [region]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

NAME="${1:?usage: provision_dev_service.sh <service_name> [region]}"
REGION="${2:-us-east-1}"

tiger_login_from_secret

log "creating ephemeral dev service '${NAME}' in ${REGION}"
# --no-wait=false blocks until ready; --output json for parsing. --with-password
# includes the master password in the output: the Tiger CLI only surfaces it at
# CREATE time, and by default (--password-storage keyring) it is stashed in a
# keyring that does not exist on the CI runner, so `tiger db uri` would otherwise
# emit a password-less URI and psql/pg_dump fail with "fe_sendauth: no password
# supplied". We capture it here and inject it into the DSN ourselves.
SVC_JSON="$(mktemp)"
trap 'rm -f "${SVC_JSON}"' EXIT
tiger service create \
  --name "${NAME}" \
  --region "${REGION}" \
  --output json \
  --with-password \
  --no-wait=false > "${SVC_JSON}" || fail "tiger service create failed"

SERVICE_ID="$(jq -r '.service_id // .id // .serviceId // empty' "${SVC_JSON}")"
[[ -n "${SERVICE_ID}" ]] || fail "could not parse service id"
log "service id: ${SERVICE_ID}"

# Publish the id IMMEDIATELY, before anything below can fail. The workflow's
# always-run teardown keys off this output, so a failure later in this script
# (password parse, DSN assembly, the readiness wait) must not hide a service
# that already exists and costs money.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "service_id=${SERVICE_ID}" >> "${GITHUB_OUTPUT}"
fi

# Grab the master password from the create response (surfaced only now, by
# --with-password). Field name varies across CLI versions; try the known ones.
SERVICE_PW="$(jq -r '.password // .initial_password // .initialPassword // .master_password // empty' "${SVC_JSON}")"
[[ -n "${SERVICE_PW}" ]] || fail "tiger service create --with-password did not return a password"
# Mask it in Actions logs before it is ever used.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "::add-mask::${SERVICE_PW}"; fi

# Build the DSN. `tiger db uri` (with --password-storage none so it never
# consults an absent keyring) returns a password-less URI; inject the captured
# password into the userinfo so psql/pg_dump authenticate non-interactively.
# No --pooled: a DIRECT (non-pooled) connection, so migration dry-runs hit the
# real server rather than the pooler (matches the original --pooled=false).
BARE_DSN="$(tiger db uri --service-id "${SERVICE_ID}" --password-storage none)"
[[ -n "${BARE_DSN}" ]] || fail "could not obtain DSN"

DSN="$(BARE_DSN="${BARE_DSN}" SERVICE_PW="${SERVICE_PW}" python3 -I -c '
import os, urllib.parse as u
p = u.urlsplit(os.environ["BARE_DSN"])
user = p.username or "tsdbadmin"
host = p.hostname or ""
if p.port:
    host += f":{p.port}"
netloc = u.quote(user, safe="") + ":" + u.quote(os.environ["SERVICE_PW"], safe="") + "@" + host
print(u.urlunsplit((p.scheme, netloc, p.path, p.query, p.fragment)))
')"
[[ -n "${DSN}" ]] || fail "could not assemble DSN with password"

# Wait until the server actually accepts connections. "Service created" can
# precede "listening": right after create, every resolved IP can answer
# "Connection refused". Retry a real login (up to ~5 min) before handing out
# the DSN, so callers never race the service coming up.
log "waiting for the service to accept connections"
ready=0
for attempt in $(seq 1 30); do
  if PGCONNECT_TIMEOUT=5 psql "${DSN}" -qXAt -c 'SELECT 1' >/dev/null 2>&1; then
    ready=1
    break
  fi
  log "not accepting connections yet (attempt ${attempt}/30); retrying in 10s"
  sleep 10
done
[[ "${ready}" -eq 1 ]] || fail "service ${SERVICE_ID} did not accept connections within ~5 minutes"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "dsn=${DSN}" >> "${GITHUB_OUTPUT}"
fi

ok "dev service ready"
echo "${DSN}"
