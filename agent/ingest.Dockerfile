# RAG ingestion runtime image.
#
# Base pulled THROUGH the ECR pull-through cache (not docker.io directly) to
# avoid Docker Hub rate limits — the registry (<account>.dkr.ecr.<region>...)
# is passed as a build arg, resolved by the build workflow via
# `aws sts get-caller-identity`. The `docker-hub/` prefix is the cache rule.
#
# ingest.py is baked in (it is CODE). The knowledge corpus (agent/knowledge/*.md)
# is NOT baked — it is MOUNTED at runtime from the git checkout, so adding/
# editing knowledge is just a commit, no image rebuild (same model as the
# Liquibase changelog). ingest.py fetches the DSN from Secrets Manager itself
# (boto3), so no entrypoint wrapper is needed.
ARG ECR_REGISTRY
FROM ${ECR_REGISTRY}/docker-hub/library/python:3.12-slim

WORKDIR /app

# Dependencies first (layer-cached).
COPY agent/ingest_requirements.txt /app/ingest_requirements.txt
RUN pip install --no-cache-dir -r /app/ingest_requirements.txt

# The ingestion code (not the corpus).
COPY agent/ingest.py /app/ingest.py

# The corpus is mounted at /app/knowledge at run time; ingest.py defaults
# RAG_KNOWLEDGE_DIR to <ingest.py dir>/knowledge == /app/knowledge.
ENTRYPOINT ["python", "/app/ingest.py"]
