--liquibase formatted sql

--changeset agentic-dataops:002_sensor_readings_id_bigint labels:sensor-readings-overflow
--comment: Widen sensor_readings.id from int4 to bigint — the NAIVE fix for the int4 overflow hazard. This single ALTER takes an ACCESS EXCLUSIVE lock and rewrites the entire ~2.1B-row (~2 TB) table, also rebuilding the primary-key index: hours of downtime with ingestion halted fleet-wide. This is the "do NOT ship this" migration migration-review's AI is meant to flag; the zero-downtime candidate approaches (A-D) are the human-chosen alternatives.
ALTER TABLE "sensor_readings" ALTER COLUMN "id" TYPE BIGINT;
--rollback ALTER TABLE "sensor_readings" ALTER COLUMN "id" TYPE INTEGER;
