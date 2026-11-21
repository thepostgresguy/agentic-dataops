--liquibase formatted sql

--changeset agentic-dataops:005_updated_at_trigger splitStatements:false
-- Keep updated_at current on row updates. splitStatements:false is required:
-- the $$-quoted function body contains internal semicolons that Liquibase's
-- formatted-SQL parser would otherwise split on, breaking the statement. The
-- function/trigger use CREATE OR REPLACE / DROP ... IF EXISTS so re-running is
-- idempotent.
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
--rollback DROP TRIGGER IF EXISTS rag_documents_updated_at ON rag_documents;
--rollback DROP FUNCTION IF EXISTS rag_documents_set_updated_at();
