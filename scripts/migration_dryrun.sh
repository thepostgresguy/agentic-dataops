#!/usr/bin/env bash
#
# Dry-run a migration on an EPHEMERAL dev service and collect evidence.
#
# Applies the SQL inside ONE transaction and, before committing, records what
# PostgreSQL actually did:
#   - lock modes held on each table (pg_locks for this backend)
#   - which relations were physically rewritten (relfilenode changed)
#   - elapsed time
# If the SQL fails, the transaction rolls back and the error is reported as the
# result (e.g. ADD COLUMN ... NOT NULL with no default on a populated table).
# The evidence file is what the AI consultant reads next to the SQL.
#
# NEVER point this at the app/prod DB — it is for ephemeral services only.
#
# Prisma emits serial pseudo-types in ALTER COLUMN ... TYPE (e.g.
# `SET DATA TYPE BIGSERIAL`) that PostgreSQL rejects. They are normalized to the
# real types before applying; the original SQL is what the agent reviews.
#
# Usage: migration_dryrun.sh <ephemeral_dsn> <migration.sql> <evidence_out>
# Exit: 0 always when the dry run executed (result is in the evidence file);
#       non-zero only on usage/connectivity errors.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

DSN="${1:?usage: migration_dryrun.sh <ephemeral_dsn> <migration.sql> <evidence_out>}"
SQL_FILE="${2:?missing migration.sql}"
OUT="${3:?missing evidence_out}"
[[ -s "${SQL_FILE}" ]] || fail "migration SQL file is empty or missing: ${SQL_FILE}"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
APPLY_SQL="${WORK}/apply.sql"
sed -E 's/SET DATA TYPE BIGSERIAL/SET DATA TYPE BIGINT/Ig; s/SET DATA TYPE SERIAL/SET DATA TYPE INTEGER/Ig' \
  "${SQL_FILE}" > "${APPLY_SQL}"

# Generic dataset-size hint: the largest user table's estimated row count (from
# planner stats). Works for ANY schema; no hardcoded table name. Best-effort.
ROWS="$(psql_do "${DSN}" "
  SELECT coalesce(max(c.reltuples)::bigint, 0)
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r'
" 2>/dev/null || echo 0)"
log "dry-running on ephemeral service (largest table est. rows: ${ROWS})"

PROBE="${WORK}/probe.sql"
cat > "${PROBE}" <<SQL
\\set ON_ERROR_STOP on
\\pset tuples_only on
\\pset format unaligned
BEGIN;
CREATE TEMP TABLE _before AS
  SELECT c.oid::regclass::text AS rel, c.relfilenode
    FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace
     AND c.relkind IN ('r', 'i');
SELECT clock_timestamp() AS t0 \\gset
\\i ${APPLY_SQL}
SELECT 'ELAPSED_SECONDS=' || round(extract(epoch FROM clock_timestamp() - :'t0'::timestamptz)::numeric, 3);
-- Heavy locks the migration took, on ANY user table in public (not a fixed
-- list) — so this works for any schema change. System catalogs are excluded.
SELECT 'LOCK ' || l.relation::regclass::text || ' ' || l.mode
  FROM pg_locks l
  JOIN pg_class c ON c.oid = l.relation
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE l.pid = pg_backend_pid() AND l.locktype = 'relation'
   AND n.nspname = 'public'
   AND l.mode IN ('AccessExclusiveLock', 'ExclusiveLock', 'ShareRowExclusiveLock', 'ShareLock')
 ORDER BY 1;
SELECT 'REWRITTEN ' || b.rel
  FROM _before b JOIN pg_class c ON c.oid = b.rel::regclass
 WHERE c.relfilenode <> b.relfilenode
 ORDER BY 1;
COMMIT;
SQL

RESULT="${WORK}/result.txt"; ERR="${WORK}/err.txt"
if psql "${DSN}" -qX -f "${PROBE}" > "${RESULT}" 2> "${ERR}"; then STATUS="APPLIED"; else STATUS="FAILED"; fi

{
  echo "DRY-RUN ON EPHEMERAL CLONE (largest table est. ${ROWS} rows)"
  echo "RESULT: ${STATUS}"
  if [[ "${STATUS}" == "APPLIED" ]]; then
    grep -E '^ELAPSED_SECONDS=' "${RESULT}" || true
    echo "LOCKS HELD AT END OF TRANSACTION:"
    grep -E '^LOCK ' "${RESULT}" | sed 's/^/  /' || echo "  (no table-level exclusive locks observed)"
    if grep -q '^REWRITTEN ' "${RESULT}"; then
      echo "FULL REWRITE: YES (relations with a new on-disk file):"
      grep -E '^REWRITTEN ' "${RESULT}" | sed 's/^REWRITTEN /  /'
    else
      echo "FULL REWRITE: NO (no relation was rewritten)"
    fi
  else
    echo "ERROR (migration rolled back; nothing was applied):"
    sed 's/^/  /' "${ERR}"
  fi
} > "${OUT}"

cat "${OUT}" >&2
ok "dry run complete: ${STATUS}"
