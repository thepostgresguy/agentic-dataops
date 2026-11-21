--liquibase formatted sql

--changeset agentic-dataops:003_storage_external
-- Store the large/variable columns out of line in TOAST, uncompressed, so the
-- main heap stays compact and these columns are read only when selected.
-- ALTER ... SET STORAGE is idempotent (setting the same mode again is a no-op).
ALTER TABLE rag_documents ALTER COLUMN content  SET STORAGE EXTERNAL;
ALTER TABLE rag_documents ALTER COLUMN metadata SET STORAGE EXTERNAL;
--rollback ALTER TABLE rag_documents ALTER COLUMN content  SET STORAGE EXTENDED;
--rollback ALTER TABLE rag_documents ALTER COLUMN metadata SET STORAGE EXTENDED;
