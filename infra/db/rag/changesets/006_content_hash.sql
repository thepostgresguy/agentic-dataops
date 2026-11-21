--liquibase formatted sql

--changeset agentic-dataops:006_content_hash
-- Add a stable per-chunk content hash so RAG ingestion can upsert idempotently
-- (incremental mode): a unique index on content_hash lets re-ingestion skip
-- unchanged chunks (INSERT ... ON CONFLICT (content_hash) DO NOTHING) without
-- duplicating rows. Nullable so it is additive on the already-populated table;
-- the ingester always sets it. The unique index excludes NULLs (standard
-- Postgres), so pre-existing rows without a hash are unaffected.
ALTER TABLE rag_documents ADD COLUMN IF NOT EXISTS content_hash text;

ALTER TABLE rag_documents ALTER COLUMN content_hash SET STORAGE EXTERNAL;

CREATE UNIQUE INDEX IF NOT EXISTS rag_documents_content_hash_uidx
    ON rag_documents (content_hash);
--rollback DROP INDEX IF EXISTS rag_documents_content_hash_uidx;
--rollback ALTER TABLE rag_documents ALTER COLUMN content_hash SET STORAGE EXTENDED;
--rollback ALTER TABLE rag_documents DROP COLUMN IF EXISTS content_hash;
