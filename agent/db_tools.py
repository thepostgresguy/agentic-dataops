"""Read-only database tools that make the consultant an agentic workload.

When a caller (the `migration-test` workflow) supplies a DSN for an EPHEMERAL
Tiger service, the agent gets these tools and decides for itself which lookups
to run before answering: reason -> call a tool -> observe -> repeat.

Guardrails, layered (any one of them alone would block a write):
  1. The DSN is for a dedicated `agent_ro` role created by the workflow on the
     ephemeral service: SELECT-only grants, default_transaction_read_only=on,
     role-level statement_timeout. It is never a prod or tsdbadmin credential.
  2. Every call runs in its own `BEGIN READ ONLY` transaction with a
     transaction-local statement_timeout, and is always rolled back.
  3. Only one statement per call (psycopg 3 uses the extended query protocol,
     which rejects multi-statement strings) and only statements that start
     with SELECT / WITH / EXPLAIN / SHOW / TABLE / VALUES.
  4. Results are capped at MAX_ROWS rows and MAX_CHARS characters.
  5. A per-invocation tool-call budget bounds the loop (MAX_CALLS).

Every call and its outcome is logged to stderr (CloudWatch) and recorded in
`trace` so the caller can show exactly what the agent did.
"""

from __future__ import annotations

import re
import sys
import time
from dataclasses import dataclass, field

from strands import tool

MAX_CALLS = 12
MAX_ROWS = 50
MAX_CHARS = 6000
STATEMENT_TIMEOUT_MS = 5000
CONNECT_TIMEOUT_S = 10

_ALLOWED_START = re.compile(r"^\s*(select|with|explain|show|table|values)\b", re.IGNORECASE)
_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$")


def _log(msg: str) -> None:
    print(f"[agent-tools] {msg}", file=sys.stderr, flush=True)


def _strip_sql_comments(sql: str) -> str:
    sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.DOTALL)
    return re.sub(r"--[^\n]*", " ", sql)


def _format_rows(cols: list[str], rows: list[tuple], truncated: bool) -> str:
    if not rows:
        return f"columns: {', '.join(cols)}\n(0 rows)"
    lines = [" | ".join(cols)]
    lines += [" | ".join("NULL" if v is None else str(v) for v in r) for r in rows]
    out = "\n".join(lines)
    if truncated:
        out += f"\n... (truncated to {MAX_ROWS} rows)"
    if len(out) > MAX_CHARS:
        out = out[:MAX_CHARS] + "\n... (output truncated)"
    return out


@dataclass
class DbToolSession:
    """Holds the DSN, the call budget and the trace for ONE invocation."""

    dsn: str
    calls: int = 0
    trace: list[dict] = field(default_factory=list)

    def _run(self, tool_name: str, sql: str, params: dict | None = None) -> str:
        if self.calls >= MAX_CALLS:
            msg = (
                f"Tool-call budget exhausted ({MAX_CALLS} calls). Stop calling tools "
                "and write your answer from what you have observed."
            )
            self.trace.append({"tool": tool_name, "sql": sql, "status": "budget", "result": msg})
            return msg
        self.calls += 1
        n = self.calls
        _log(f"call {n}/{MAX_CALLS} {tool_name}: {sql[:300]!r}")
        t0 = time.monotonic()
        try:
            import psycopg

            with psycopg.connect(self.dsn, connect_timeout=CONNECT_TIMEOUT_S) as conn:
                with conn.cursor() as cur:
                    # psycopg opens a transaction implicitly; make it read-only
                    # and time-bounded before the agent's statement runs.
                    cur.execute("SET TRANSACTION READ ONLY")
                    cur.execute(f"SET LOCAL statement_timeout = {int(STATEMENT_TIMEOUT_MS)}")
                    cur.execute(sql, params)
                    if cur.description is None:
                        result = "(statement returned no rows)"
                    else:
                        cols = [d.name for d in cur.description]
                        rows = cur.fetchmany(MAX_ROWS + 1)
                        result = _format_rows(cols, rows[:MAX_ROWS], len(rows) > MAX_ROWS)
                conn.rollback()
            status = "ok"
        except Exception as e:  # noqa: BLE001 - errors are returned to the agent as data
            status = "error"
            result = f"ERROR ({type(e).__name__}): {str(e).strip()[:1000]}"
        ms = round((time.monotonic() - t0) * 1000)
        _log(f"call {n} {status} in {ms} ms")
        self.trace.append(
            {"n": n, "tool": tool_name, "sql": sql, "status": status, "ms": ms, "result": result}
        )
        return result

    def tools(self) -> list:
        session = self

        @tool
        def describe_table(table: str) -> str:
            """Describe a table on the ephemeral clone: columns and types, the
            primary key, indexes, foreign keys in BOTH directions (which tables
            reference it, and which it references), dependent views, triggers,
            and estimated row count / on-disk size.

            Args:
                table: Table name, optionally schema-qualified (e.g.
                    "sensor_readings" or "public.sensor_readings").
            """
            if not _IDENT.match(table or ""):
                return "ERROR: table must be a plain identifier like sensor_readings or public.sensor_readings"
            qualified = table if "." in table else f"public.{table}"
            sql = """
            WITH t AS (SELECT to_regclass(%(t)s) AS oid)
            SELECT 'column' AS kind, a.attname AS name,
                   format_type(a.atttypid, a.atttypmod)
                     || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END
                     || coalesce(' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid), '') AS detail
              FROM t JOIN pg_attribute a ON a.attrelid = t.oid
              LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
             WHERE a.attnum > 0 AND NOT a.attisdropped
            UNION ALL
            SELECT CASE c.contype WHEN 'p' THEN 'primary_key' WHEN 'u' THEN 'unique'
                                  WHEN 'f' THEN 'fk_out' WHEN 'c' THEN 'check' ELSE c.contype::text END,
                   c.conname, pg_get_constraintdef(c.oid)
              FROM t JOIN pg_constraint c ON c.conrelid = t.oid
            UNION ALL
            SELECT 'fk_in', c.conname, c.conrelid::regclass::text || ' ' || pg_get_constraintdef(c.oid)
              FROM t JOIN pg_constraint c ON c.confrelid = t.oid AND c.contype = 'f'
            UNION ALL
            SELECT 'index', i.indexrelid::regclass::text, pg_get_indexdef(i.indexrelid)
              FROM t JOIN pg_index i ON i.indrelid = t.oid
            UNION ALL
            SELECT DISTINCT 'dependent_view', v.oid::regclass::text, v.relkind::text
              FROM t JOIN pg_depend dp ON dp.refobjid = t.oid
              JOIN pg_rewrite r ON r.oid = dp.objid
              JOIN pg_class v ON v.oid = r.ev_class AND v.oid <> t.oid
            UNION ALL
            SELECT 'trigger', tg.tgname, pg_get_triggerdef(tg.oid)
              FROM t JOIN pg_trigger tg ON tg.tgrelid = t.oid AND NOT tg.tgisinternal
            UNION ALL
            SELECT 'stats', 'estimated_rows / total_size',
                   c.reltuples::bigint::text || ' / ' || pg_size_pretty(pg_total_relation_size(c.oid))
              FROM t JOIN pg_class c ON c.oid = t.oid
            """
            return session._run("describe_table", sql.strip(), {"t": qualified})

        @tool
        def run_readonly_query(sql: str) -> str:
            """Run ONE read-only SQL statement on the ephemeral clone and return
            up to 50 rows. Allowed: SELECT, WITH, EXPLAIN (incl. EXPLAIN ANALYZE
            of a SELECT), SHOW, TABLE, VALUES. Use it for catalog queries
            (pg_class, pg_index, pg_constraint, pg_sequences, pg_locks,
            information_schema, timescaledb_information.*), sequence state, and
            query plans. Writes and DDL are rejected. 5-second timeout.

            Args:
                sql: A single read-only SQL statement, no trailing semicolon needed.
            """
            body = _strip_sql_comments(sql or "").strip().rstrip(";").strip()
            if not body:
                return "ERROR: empty statement"
            if not _ALLOWED_START.match(body):
                return "ERROR: only SELECT / WITH / EXPLAIN / SHOW / TABLE / VALUES statements are allowed"
            if ";" in body:
                return "ERROR: exactly one statement per call"
            return session._run("run_readonly_query", body)

        return [describe_table, run_readonly_query]
