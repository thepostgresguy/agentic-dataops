# DB-consultant agent image for Amazon Bedrock AgentCore Runtime.
# Runs app.py (the AgentCore entrypoint). Reads migration SQL passed in the
# request, retrieves RAG context, and calls Bedrock (Nova Pro) to advise. When
# the request carries an ephemeral read-only DSN (migration-test), it also runs
# read-only tools against that ephemeral service (agent/db_tools.py).
#
# AgentCore CONTAINER CONTRACT (required, or the runtime rejects the image):
#   - ARM64 architecture  -> --platform=linux/arm64 (pinned below)
#   - serves POST /invocations and GET /ping on 0.0.0.0:8080
#     (the bedrock-agentcore SDK's app.run() provides these on 8080)
#   - a numeric USER
# Build for arm64 explicitly (works on Apple Silicon natively; on Intel use
# buildx/QEMU): docker build --platform linux/arm64 ...

FROM --platform=linux/arm64 public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY agent/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# The package lives at /app/agent so `python -m agent.app` works.
COPY agent/ ./agent/

ENV BEDROCK_MODEL_ID=amazon.nova-pro-v1:0

# AgentCore requires the agent on 0.0.0.0:8080 serving /invocations and /ping.
EXPOSE 8080

# Numeric non-root user (AgentCore contract).
USER 1000

# AgentCore invokes the entrypoint; app.run() serves the handler contract.
ENTRYPOINT ["python", "-m", "agent.app"]
