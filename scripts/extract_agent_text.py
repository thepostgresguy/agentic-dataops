#!/usr/bin/env python3
"""Turn a raw AgentCore invoke-agent-runtime response into plain text.

The runtime streams the handler's yields as server-sent events (`data: <json>`
lines). Each `data:` payload is JSON:
  - a string               -> a text delta of the answer (concatenated)
  - {"data": str}          -> a text delta of the answer
  - {"trace": str}         -> one agent-step line (tool call / result); written
                              to --trace-out if given, else dropped
If the body is not SSE, the raw text is returned unchanged.

Usage: extract_agent_text.py <response_file> [--trace-out <file>]
       (prints the answer text to stdout)
"""
import json
import sys


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 4) or (len(argv) == 4 and argv[2] != "--trace-out"):
        print("usage: extract_agent_text.py <response_file> [--trace-out <file>]", file=sys.stderr)
        return 2
    trace_out = argv[3] if len(argv) == 4 else None

    raw = open(argv[1], "r", encoding="utf-8", errors="replace").read()
    parts, traces, saw_sse = [], [], False
    for line in raw.splitlines():
        if not line.startswith("data:"):
            continue
        saw_sse = True
        payload = line[len("data:"):].strip()
        try:
            val = json.loads(payload)
        except ValueError:
            parts.append(payload)
            continue
        if isinstance(val, str):
            parts.append(val)
        elif isinstance(val, dict) and isinstance(val.get("trace"), str):
            traces.append(val["trace"])
        elif isinstance(val, dict) and isinstance(val.get("data"), str):
            parts.append(val["data"])

    if trace_out is not None:
        with open(trace_out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(traces) + ("\n" if traces else ""))

    if saw_sse:
        sys.stdout.write("".join(parts))
        return 0
    # Not SSE: either a bare JSON string or plain text.
    try:
        val = json.loads(raw)
        if isinstance(val, str):
            raw = val
    except ValueError:
        pass
    sys.stdout.write(raw)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
