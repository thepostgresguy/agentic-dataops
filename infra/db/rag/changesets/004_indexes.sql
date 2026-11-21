--liquibase formatted sql

--changeset agentic-dataops:004_indexes
-- StreamingDiskANN index for cosine-distance similarity search (verified DDL
-- from the pgvectorscale README: USING diskann (<col> vector_cosine_ops);
-- cosine distance is queried with the <=> operator), plus a GIN index on
-- metadata for provenance/tag filters alongside vector search.
CREATE INDEX IF NOT EXISTS rag_documents_embedding_diskann
    ON rag_documents
    USING diskann (embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS rag_documents_metadata_gin
    ON rag_documents
    USING gin (metadata);
--rollback DROP INDEX IF EXISTS rag_documents_embedding_diskann;
--rollback DROP INDEX IF EXISTS rag_documents_metadata_gin;
