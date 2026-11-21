"""Always-on RAG retrieval for the consultant agent.

Before the agent analyzes a migration, we embed the query (the migration SQL /
question) with Titan Text Embeddings v2, vector-search the top-k most similar
chunks from public.rag_documents (pgvectorscale cosine distance), and return
them as grounding context to prepend to the prompt. This is NOT a Strands tool
— retrieval runs in plain code before the prompt is built, so the agent stays
tool-less (avoiding the retry loops noted in consultant.py).

Connectivity: runs in-VPC (AgentCore runtime attached to the peer VPC), reaching
the private RAG endpoint over the peering and Bedrock/Secrets Manager via the
VPC endpoints. The DSN comes from the agentic-dataops/tiger/rag secret via the
agent's IAM role — never hardcoded.

Retrieval is BEST-EFFORT: if the store is unreachable/empty or embedding fails,
we log and return no context rather than failing the whole analysis. The agent
still answers from the base model; retrieval only enriches.
"""

from __future__ import annotations

import json
import os
import sys

REGION = os.environ.get("AWS_REGION", "us-east-1")
SECRET_ID = os.environ.get("RAG_SECRET_ID", "agentic-dataops/tiger/rag")
EMBED_MODEL_ID = os.environ.get("BEDROCK_EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
EMBED_DIM = int(os.environ.get("RAG_EMBED_DIM", "1024"))
TOP_K = int(os.environ.get("RAG_TOP_K", "5"))
# Retrieval can be disabled (e.g. local CLI with no DB access) via env.
RETRIEVAL_ENABLED = os.environ.get("RAG_RETRIEVAL_ENABLED", "1") not in ("0", "false", "False")


def _log(msg: str) -> None:
    print(f"[rag-retrieval] {msg}", file=sys.stderr, flush=True)


def _dsn() -> str:
    import boto3

    sm = boto3.client("secretsmanager", region_name=REGION)
    data = json.loads(sm.get_secret_value(SecretId=SECRET_ID)["SecretString"])
    dbname = data.get("dbname", "tsdb")
    return (
        f"host={data['host']} port={data['port']} dbname={dbname} "
        f"user={data['username']} password={data['password']} "
        f"sslmode=require options=-csearch_path=public"
    )


def _embed(text: str) -> list[float]:
    import boto3

    bedrock = boto3.client("bedrock-runtime", region_name=REGION)
    body = json.dumps({"inputText": text, "dimensions": EMBED_DIM, "normalize": True})
    resp = bedrock.invoke_model(modelId=EMBED_MODEL_ID, body=body)
    return json.loads(resp["body"].read())["embedding"]


def _to_pgvector(vec: list[float]) -> str:
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"


def retrieve_context(query: str, top_k: int = TOP_K) -> str:
    """Return the top-k most relevant knowledge passages for `query`, formatted
    for prompt injection. Returns "" on any failure (best-effort)."""
    if not RETRIEVAL_ENABLED:
        return ""
    try:
        import psycopg

        qvec = _to_pgvector(_embed(query))
        with psycopg.connect(_dsn(), autocommit=True) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    SELECT content, metadata
                    FROM rag_documents
                    ORDER BY embedding <=> %s::vector
                    LIMIT %s
                    """,
                    (qvec, top_k),
                )
                rows = cur.fetchall()
    except Exception as e:  # noqa: BLE001 - retrieval is best-effort
        _log(f"retrieval skipped ({type(e).__name__}); answering without RAG context")
        return ""

    if not rows:
        _log("no knowledge rows found; answering without RAG context")
        return ""

    parts = []
    for content, metadata in rows:
        src = (metadata or {}).get("source", "knowledge") if isinstance(metadata, dict) else "knowledge"
        parts.append(f"[source: {src}]\n{content}")
    _log(f"retrieved {len(rows)} passage(s)")
    return "\n\n---\n\n".join(parts)
