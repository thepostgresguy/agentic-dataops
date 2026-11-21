--liquibase formatted sql

--changeset agentic-dataops:001_extensions
-- pgvector provides the `vector` type; pgvectorscale adds the StreamingDiskANN
-- index. CASCADE pulls in pgvector as a dependency. IF NOT EXISTS keeps this
-- idempotent so it is safe even though the extensions were enabled by hand on
-- the live service.
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
--rollback DROP EXTENSION IF EXISTS vectorscale;
--rollback DROP EXTENSION IF EXISTS vector;
