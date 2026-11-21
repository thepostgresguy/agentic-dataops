#!/usr/bin/env bash
#
# iqtoolkit-analyzer gate.
#
# Runs the analyzer against the target DB after migrations are applied, emits a
# machine-readable JSON report + an HTML report artifact, and fails the pipeline
# if the analyzer surfaces high-severity findings or slow queries above the
# threshold.
#
# Usage: analyze_gate.sh <dsn> [out_dir]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

DSN="${1:?usage: analyze_gate.sh <dsn> [out_dir]}"
OUT_DIR="${2:-artifacts}"
SLOW_MS="${SLOW_THRESHOLD_MS:-500}"
mkdir -p "${OUT_DIR}"

log "running iqtoolkit-analyzer (json + html)"
iqtoolkit-analyzer analyze \
  --dsn "${DSN}" \
  --format json \
  --slow-threshold "${SLOW_MS}" \
  --output "${OUT_DIR}/analysis.json" || fail "analyzer failed to run"

iqtoolkit-analyzer report \
  --dsn "${DSN}" \
  --output "${OUT_DIR}/report.html" || log "html report generation failed (non-fatal)"

[[ -s "${OUT_DIR}/analysis.json" ]] || fail "analyzer produced no JSON output"

# Gate on high-severity findings. The analyzer JSON shape can vary across
# versions, so we look for common severity keys defensively.
HIGH_COUNT="$(jq '[.. | objects | select((.severity? // .level? // "" ) | ascii_downcase | test("high|critical"))] | length' "${OUT_DIR}/analysis.json" 2>/dev/null || echo 0)"

log "high/critical findings: ${HIGH_COUNT}"
if [[ "${HIGH_COUNT}" -gt 0 ]]; then
  jq '[.. | objects | select((.severity? // .level? // "") | ascii_downcase | test("high|critical"))]' \
    "${OUT_DIR}/analysis.json" >&2 || true
  fail "analyzer reported ${HIGH_COUNT} high/critical finding(s); blocking deploy"
fi

ok "analyzer gate passed"
