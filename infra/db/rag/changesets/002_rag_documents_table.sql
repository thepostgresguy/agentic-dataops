--liquibase formatted sql

--changeset agentic-dataops:002_rag_documents_table
-- The knowledge-base table. One row per retrievable chunk.
--   content   : the chunk text (TOAST-able).
--   metadata  : provenance/tags (source, type, title, ...) as JSONB.
--   embedding : the Titan Text Embeddings v2 (1024-dim) embedding of content.
CREATE TABLE IF NOT EXISTS rag_documents (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    content    text          NOT NULL,
    metadata   jsonb         NOT NULL DEFAULT '{}'::jsonb,
    embedding  vector(1024)  NOT NULL,
    created_at timestamptz   NOT NULL DEFAULT now(),
    updated_at timestamptz   NOT NULL DEFAULT now()
);
--rollback DROP TABLE IF EXISTS rag_documents;
