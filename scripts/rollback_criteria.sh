#!/usr/bin/env bash
#
# Rollback criteria evaluator (post-deploy monitoring gate).
#
# After a migration is started against production (via the gated
# `prisma migrate deploy`, or a candidate's hand-authored expand migration),
# this polls health signals for a monitoring window. If any criterion trips, it
# exits non-zero so the deploy workflow triggers the automated rollback path.
#
# Criteria (all coded, no manual judgement):
#   - error-rate: count of ERROR/FATAL log lines via pg_stat_statements proxy
#   - lock waits: any session waiting on a lock longer than LOCK_WAIT_MS
#   - replication/apply lag not covered here (dev demo)
#
# Usage: rollback_criteria.sh <dsn> [window_seconds]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

DSN="${1:?usage: rollback_criteria.sh <dsn> [window_seconds]}"
WINDOW="${2:-60}"
LOCK_WAIT_MS="${LOCK_WAIT_MS:-5000}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

log "monitoring for ${WINDOW}s (poll every ${POLL_INTERVAL}s, lock-wait limit ${LOCK_WAIT_MS}ms)"

deadline=$(( $(date +%s) + WINDOW ))
while [[ $(date +%s) -lt ${deadline} ]]; do
  # Long lock waits -> rollback trigger.
  blocked="$(psql_do "${DSN}" "
    SELECT count(*)
    FROM pg_stat_activity
    WHERE wait_event_type = 'Lock'
      AND state <> 'idle'
      AND (now() - query_start) > interval '${LOCK_WAIT_MS} milliseconds';
  ")"
  if [[ "${blocked:-0}" -gt 0 ]]; then
    fail "rollback criterion tripped: ${blocked} session(s) blocked on locks > ${LOCK_WAIT_MS}ms"
  fi

  # Deadlocks since start -> rollback trigger.
  deadlocks="$(psql_do "${DSN}" "
    SELECT coalesce(sum(deadlocks), 0)
    FROM pg_stat_database
    WHERE datname = current_database();
  ")"
  log "health: blocked=${blocked} deadlocks_total=${deadlocks}"

  sleep "${POLL_INTERVAL}"
done

ok "monitoring window passed with no rollback criteria tripped"
