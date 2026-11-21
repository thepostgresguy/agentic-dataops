-- RAG vector store schema for the permanent, private Tiger Cloud service
-- (agentic-dataops-rag). This turns the service into a real vector store the
-- DB-consultant agent retrieves from.
--
-- APPLY MODEL (charter: no manual steps): this committed SQL is applied by a
-- coded, idempotent, in-VPC step (a workflow-invoked job that can reach the
-- PRIVATE endpoint over the VPC peering and reads the tsdbadmin DSN from the
-- secret agentic-dataops/tiger/rag). It is NOT run by hand with psql. Every
-- statement is idempotent (IF NOT EXISTS), so re-applying is safe — the file is
-- the single source of truth and can be re-run on every deploy, or dropped into
-- a Liquibase changeset later without change.
--
-- EMBEDDINGS: vectors are 1024-dimensional to match Amazon Titan Text
-- Embeddings v2 (the default embedding model for this project). If the
-- embedding model/dimension changes, the vector(N) dimension below and the
-- ingestion/retrieval code must change together — the column dimension is
-- fixed and must equal the model's output size.

-- 1. Extensions. pgvector provides the `vector` type; pgvectorscale adds the
--    StreamingDiskANN index. CASCADE pulls in pgvector as a dependency. Both
--    are idempotent; already enabled on this service but kept here so the
--    schema is reproducible from scratch.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;

-- 2. The knowledge-base table. One row per retrievable chunk.
--    - content : the chunk text (TOAST-able; stored out of line, see below).
--    - metadata: arbitrary provenance/tags (source, type, title, ...) as JSONB.
--    - embedding: the Titan v2 (1024-dim) embedding of `content`.
CREATE TABLE IF NOT EXISTS rag_documents (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    content      text          NOT NULL,
    metadata     jsonb         NOT NULL DEFAULT '{}'::jsonb,
    embedding    vector(1024)  NOT NULL,
    content_hash text,          -- stable per-chunk hash for idempotent ingestion
    created_at   timestamptz   NOT NULL DEFAULT now(),
    updated_at   timestamptz   NOT NULL DEFAULT now()
);

-- Unique content hash so RAG ingestion can upsert idempotently (incremental):
-- INSERT ... ON CONFLICT (content_hash) DO NOTHING skips unchanged chunks.
CREATE UNIQUE INDEX IF NOT EXISTS rag_documents_content_hash_uidx
    ON rag_documents (content_hash);

-- 3. STORAGE EXTERNAL on the large/variable columns (per request): store these
--    out of line in TOAST and WITHOUT compression, so the main heap stays
--    compact and these columns are read only when selected. ALTER ... SET
--    STORAGE is idempotent (setting the same mode again is a no-op).
ALTER TABLE rag_documents ALTER COLUMN content  SET STORAGE EXTERNAL;
ALTER TABLE rag_documents ALTER COLUMN metadata SET STORAGE EXTERNAL;
ALTER TABLE rag_documents ALTER COLUMN content_hash SET STORAGE EXTERNAL;

-- 4. StreamingDiskANN index for cosine-distance similarity search.
--    Verified DDL from the pgvectorscale README: `USING diskann (<col>
--    vector_cosine_ops)`. Cosine distance is queried with the `<=>` operator.
--    IF NOT EXISTS keeps the apply idempotent; the index is named explicitly so
--    re-runs match the existing object.
CREATE INDEX IF NOT EXISTS rag_documents_embedding_diskann
    ON rag_documents
    USING diskann (embedding vector_cosine_ops);

-- 5. A GIN index on metadata so provenance/tag filters are efficient alongside
--    vector search.
CREATE INDEX IF NOT EXISTS rag_documents_metadata_gin
    ON rag_documents
    USING gin (metadata);

-- 6. Keep updated_at current on row updates.
CREATE OR REPLACE FUNCTION rag_documents_set_updated_at()
RETURNS trigger AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS rag_documents_updated_at ON rag_documents;
CREATE TRIGGER rag_documents_updated_at
    BEFORE UPDATE ON rag_documents
    FOR EACH ROW
    EXECUTE FUNCTION rag_documents_set_updated_at();
