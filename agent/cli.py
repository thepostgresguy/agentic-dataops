"""Local CLI to test the consultant against a migration file — no AgentCore.

Usage:
    export BEDROCK_MODEL_ID=amazon.nova-pro-v1:0   # optional; this is the default
    # (needs AWS creds with bedrock:InvokeModel for the model, region us-east-1)
    python -m agent.cli infra/db/app/changesets/001_baseline.sql

Prints the consultant's advice to stdout. Lets you verify the agent gives good
guidance BEFORE building the image / standing up the AgentCore runtime.
"""

from __future__ import annotations

import sys

from .consultant import analysis_prompt_for_sql, build_agent, read_migration_sql


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(
            "usage: python -m agent.cli <path-to-migration.sql> [evidence.txt]",
            file=sys.stderr,
        )
        return 2

    sql = read_migration_sql(argv[1])
    evidence = read_migration_sql(argv[2]) if len(argv) == 3 else None
    agent = build_agent()
    result = agent(analysis_prompt_for_sql(sql, evidence))
    # Strands Agent returns a result whose str() is the final text.
    print(str(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
