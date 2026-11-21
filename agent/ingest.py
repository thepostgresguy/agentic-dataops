"""RAG ingestion: embed the knowledge corpus into the RAG vector store.

Reads the markdown corpus under agent/knowledge/, chunks it, embeds each chunk
with Amazon Titan Text Embeddings v2 (1024-dim) via Bedrock, and upserts the
chunks into public.rag_documents on the permanent, private RAG Tiger service.

Idempotency is keyed on a per-chunk content_hash (sha256 of the chunk text),
which has a UNIQUE index (changeset 006):
  - incremental (default): INSERT ... ON CONFLICT (content_hash) DO NOTHING, so
    re-running only inserts new/changed chunks.
  - full: TRUNCATE rag_documents first, then insert everything.

Credentials: the DSN comes from AWS Secrets Manager (agentic-dataops/tiger/rag),
fetched at runtime via the task/runner IAM role — never hardcoded. Runs in-VPC
so it reaches the private RAG endpoint over the peering, and reaches Bedrock +
Secrets Manager via the VPC interface endpoints.

Env:
  RAG_INGEST_MODE   incremental (default) | full
  RAG_SECRET_ID     secret id (default agentic-dataops/tiger/rag)
  AWS_REGION        default us-east-1
  BEDROCK_EMBED_MODEL_ID  default amazon.titan-embed-text-v2:0
  RAG_KNOWLEDGE_DIR default <this file's dir>/knowledge
  RAG_EMBED_DIM     default 1024 (must match the vector(N) column)
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path

import boto3
import psycopg

REGION = os.environ.get("AWS_REGION", "us-east-1")
SECRET_ID = os.environ.get("RAG_SECRET_ID", "agentic-dataops/tiger/rag")
EMBED_MODEL_ID = os.environ.get("BEDROCK_EMBED_MODEL_ID", "amazon.titan-embed-text-v2:0")
EMBED_DIM = int(os.environ.get("RAG_EMBED_DIM", "1024"))
MODE = os.environ.get("RAG_INGEST_MODE", "incremental").lower()
KNOWLEDGE_DIR = Path(
    os.environ.get("RAG_KNOWLEDGE_DIR", str(Path(__file__).resolve().parent / "knowledge"))
)

# Chunking: paragraph-aware, bounded size with overlap so retrieval returns
# focused passages while preserving some context across boundaries.
CHUNK_MAX_CHARS = int(os.environ.get("RAG_CHUNK_MAX_CHARS", "1000"))
CHUNK_OVERLAP_CHARS = int(os.environ.get("RAG_CHUNK_OVERLAP_CHARS", "150"))


def log(msg: str) -> None:
    print(f"[rag-ingest] {msg}", file=sys.stderr, flush=True)


def die(msg: str) -> None:
    print(f"[rag-ingest][ERROR] {msg}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def get_dsn() -> str:
    """Build a libpq DSN from the RAG secret (never logs secret values)."""
    log(f"fetching RAG credentials from Secrets Manager ({SECRET_ID} in {REGION})")
    sm = boto3.client("secretsmanager", region_name=REGION)
    try:
        raw = sm.get_secret_value(SecretId=SECRET_ID)["SecretString"]
    except Exception as e:  # noqa: BLE001 - surface a clean message, no secret
        die(f"failed to fetch secret {SECRET_ID}: {type(e).__name__}")
    data = json.loads(raw)
    for field in ("host", "port", "username", "password"):
        if not data.get(field):
            die(f"secret {SECRET_ID} missing field: {field}")
    dbname = data.get("dbname", "tsdb")
    # sslmode=require (Tiger needs TLS); pin schema to public to match the DDL.
    return (
        f"host={data['host']} port={data['port']} dbname={dbname} "
        f"user={data['username']} password={data['password']} "
        f"sslmode=require options=-csearch_path=public"
    )


def chunk_text(text: str) -> list[str]:
    """Split on blank-line paragraphs, packing into <= CHUNK_MAX_CHARS pieces
    with a small overlap carried from the end of the previous chunk."""
    paras = [p.strip() for p in text.split("\n\n") if p.strip()]
    chunks: list[str] = []
    cur = ""
    for para in paras:
        if cur and len(cur) + 2 + len(para) > CHUNK_MAX_CHARS:
            chunks.append(cur)
            tail = cur[-CHUNK_OVERLAP_CHARS:] if CHUNK_OVERLAP_CHARS else ""
            cur = (tail + "\n\n" + para).strip() if tail else para
        else:
            cur = (cur + "\n\n" + para).strip() if cur else para
    if cur:
        chunks.append(cur)
    return chunks


def embed(bedrock, text: str) -> list[float]:
    """Embed one chunk with Titan Text Embeddings v2 (1024-dim)."""
    body = json.dumps({"inputText": text, "dimensions": EMBED_DIM, "normalize": True})
    resp = bedrock.invoke_model(modelId=EMBED_MODEL_ID, body=body)
    vec = json.loads(resp["body"].read())["embedding"]
    if len(vec) != EMBED_DIM:
        die(f"embedding dim {len(vec)} != expected {EMBED_DIM} (model/column mismatch)")
    return vec


def content_hash(source: str, idx: int, text: str) -> str:
    """Stable per-chunk hash. Includes source+index so identical boilerplate in
    different docs stays distinct, and changed text produces a new hash."""
    h = hashlib.sha256()
    h.update(source.encode())
    h.update(str(idx).encode())
    h.update(text.encode())
    return h.hexdigest()


def to_pgvector(vec: list[float]) -> str:
    """pgvector text input format: [f1,f2,...]."""
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"


def main() -> int:
    if MODE not in ("incremental", "full"):
        die(f"RAG_INGEST_MODE must be 'incremental' or 'full', got '{MODE}'")
    if not KNOWLEDGE_DIR.is_dir():
        die(f"knowledge dir not found: {KNOWLEDGE_DIR}")

    # rglob so subfolders are ingested too — notably agent/knowledge/decisions/
    # (human feedback: past migrations + verdict + chosen approach + rationale),
    # which is how the agent learns from your decisions over time.
    files = sorted(KNOWLEDGE_DIR.rglob("*.md"))
    if not files:
        die(f"no .md files in {KNOWLEDGE_DIR}")
    log(f"mode={MODE}; {len(files)} source file(s) in {KNOWLEDGE_DIR}")

    bedrock = boto3.client("bedrock-runtime", region_name=REGION)
    dsn = get_dsn()

    inserted = 0
    skipped = 0
    with psycopg.connect(dsn, autocommit=False) as conn:
        with conn.cursor() as cur:
            if MODE == "full":
                log("full mode: truncating rag_documents")
                cur.execute("TRUNCATE TABLE rag_documents;")

            for path in files:
                # Path relative to the knowledge dir, so decisions/<file>.md is
                # distinguishable from top-level docs in retrieval metadata.
                source = str(path.relative_to(KNOWLEDGE_DIR))
                chunks = chunk_text(path.read_text(encoding="utf-8"))
                log(f"{source}: {len(chunks)} chunk(s)")
                for idx, chunk in enumerate(chunks):
                    chash = content_hash(source, idx, chunk)
                    vec = embed(bedrock, chunk)
                    metadata = json.dumps(
                        {"source": source, "chunk_index": idx, "title": path.stem}
                    )
                    # ON CONFLICT (content_hash) DO NOTHING -> incremental skip.
                    cur.execute(
                        """
                        INSERT INTO rag_documents (content, metadata, embedding, content_hash)
                        VALUES (%s, %s::jsonb, %s::vector, %s)
                        ON CONFLICT (content_hash) DO NOTHING
                        """,
                        (chunk, metadata, to_pgvector(vec), chash),
                    )
                    if cur.rowcount == 1:
                        inserted += 1
                    else:
                        skipped += 1
        conn.commit()

    log(f"done: inserted={inserted} skipped(existing)={skipped} total_chunks={inserted + skipped}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
