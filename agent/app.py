"""AgentCore Runtime entrypoint for the DB-consultant agent.

This is what the container runs on Amazon Bedrock AgentCore Runtime. It exposes
the consultant via the AgentCore handler contract: a request in, the agent's
streamed advice out.

The caller sends either:
  { "prompt": "<raw migration SQL or a question>" }
or
  { "migration_sql": "<SQL text>", "evidence": "<dry-run report>",
    "inspect_dsn": "<read-only DSN of the EPHEMERAL clone>" }
                     # evidence and inspect_dsn are optional

With `inspect_dsn`, the agent gets read-only tools on that ephemeral service
(see db_tools.py) and runs an agentic loop: it decides which lookups to make
before answering. Without it, the agent is tool-less (migration-review).

Streamed output:
  - plain strings  = the answer's text deltas
  - {"trace": str} = one line per agent step (tool call / result), so the
                     caller can show what the agent did, separate from its answer

Validate input as untrusted; only typed strings are used.
"""

from __future__ import annotations

import re

from bedrock_agentcore import BedrockAgentCoreApp

from .consultant import analysis_prompt_for_sql, build_agent
from .db_tools import DbToolSession

app = BedrockAgentCoreApp()

_RESULT_PREVIEW = 400
# Nova models wrap reasoning in <thinking> tags when tools are available.
_THINKING = re.compile(r"<thinking>(.*?)</thinking>", re.DOTALL | re.IGNORECASE)


def _split_thinking(text: str) -> tuple[str, list[str]]:
    """Return (answer without <thinking> blocks, the thinking blocks)."""
    thoughts = [t.strip() for t in _THINKING.findall(text) if t.strip()]
    return _THINKING.sub("", text).strip(), thoughts


def _one_line(text: str, limit: int) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit] + " …"


def _trace_lines(message: dict, step: list[int]) -> list[str]:
    """Turn a completed Strands message into human-readable trace lines."""
    lines = []
    for block in message.get("content", []) or []:
        if not isinstance(block, dict):
            continue
        if "toolUse" in block:
            step[0] += 1
            use = block["toolUse"]
            args = use.get("input") or {}
            arg = args.get("sql") or args.get("table") or args
            lines.append(f"step {step[0]}: CALL {use.get('name')}: {_one_line(arg, 600)}")
        elif "toolResult" in block:
            res = block["toolResult"]
            texts = [c.get("text", "") for c in res.get("content", []) if isinstance(c, dict)]
            lines.append(
                f"step {step[0]}: RESULT ({res.get('status')}): "
                f"{_one_line(' '.join(texts), _RESULT_PREVIEW)}"
            )
        elif "text" in block and message.get("role") == "assistant" and block["text"].strip():
            # Reasoning the model emitted alongside a tool call.
            if any("toolUse" in b for b in message.get("content", []) if isinstance(b, dict)):
                thought = re.sub(r"</?thinking>", " ", block["text"], flags=re.IGNORECASE)
                lines.append(f"step {step[0] + 1}: THINK: {_one_line(thought, 600)}")
    return lines


@app.entrypoint
async def handler(request):
    # Treat all input as untrusted; keep values typed as strings.
    migration_sql = request.get("migration_sql")
    inspect_dsn = request.get("inspect_dsn")
    session = None
    if isinstance(inspect_dsn, str) and inspect_dsn.strip():
        session = DbToolSession(dsn=inspect_dsn.strip())

    if isinstance(migration_sql, str) and migration_sql.strip():
        evidence = request.get("evidence")
        prompt = analysis_prompt_for_sql(
            migration_sql, evidence if isinstance(evidence, str) else None
        )
    else:
        prompt = request.get("prompt")
        if not isinstance(prompt, str):
            raise ValueError("Provide a string 'prompt' or 'migration_sql'.")

    # A fresh agent per request: no conversation history leaks between
    # invocations, and the tools are bound to THIS request's ephemeral DSN.
    agent = build_agent(tools=session.tools() if session else None)
    if session:
        yield {"trace": "agentic mode: read-only tools attached to the ephemeral clone"}

    step = [0]
    pending: list[str] = []  # text deltas of the current model turn (agentic mode)
    async for event in agent.stream_async(prompt):
        if not isinstance(event, dict):
            continue
        # Stream only the text deltas; other Strands events carry non-JSON
        # objects (metrics, agent refs) the caller does not need.
        if isinstance(event.get("data"), str):
            if session:
                pending.append(event["data"])  # decide at end of turn
            else:
                yield event["data"]
        elif session and isinstance(event.get("message"), dict):
            msg = event["message"]
            for line in _trace_lines(msg, step):
                yield {"trace": line}
            if msg.get("role") == "assistant":
                calls_tool = any(
                    isinstance(b, dict) and "toolUse" in b for b in msg.get("content", []) or []
                )
                # A turn that calls a tool is interim reasoning (already in the
                # trace as THINK); only the final turn is the answer.
                if not calls_tool:
                    answer, thoughts = _split_thinking("".join(pending))
                    for t in thoughts:
                        yield {"trace": f"step {step[0] + 1}: THINK: {_one_line(t, 600)}"}
                    yield answer
                pending = []

    if session:
        if pending:  # stream ended without a closing message event
            yield _split_thinking("".join(pending))[0]
        yield {"trace": f"done: {session.calls} tool call(s) used"}


if __name__ == "__main__":
    app.run()
