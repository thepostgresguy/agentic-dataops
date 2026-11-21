-- Correctness tests for migration 0001_add_device_firmware (expand phase).
--
-- During the expand phase of a candidate's hand-authored raw-SQL
-- expand/contract migration, BOTH the old schema version (no firmware_version)
-- and the new schema version (with firmware_version) must work simultaneously
-- against the same physical `devices` table. These assertions run against the
-- NEW version schema after the expand migration runs. Each failed assertion
-- RAISEs and fails CI.
--
-- Usage (CI): psql "$DSN" -v ON_ERROR_STOP=1 -f db/tests/0001_add_device_firmware.test.sql

\set ON_ERROR_STOP on

DO $$
DECLARE
    v_new_schema text;
    v_col_exists boolean;
BEGIN
    -- The expand migration creates a version schema per migration. Find the newest one.
    SELECT nspname INTO v_new_schema
    FROM pg_namespace
    WHERE nspname LIKE 'public_%'
    ORDER BY nspname DESC
    LIMIT 1;

    IF v_new_schema IS NULL THEN
        RAISE EXCEPTION 'no version schema found; did the expand migration run?';
    END IF;

    -- The new view must expose the firmware_version column.
    EXECUTE format(
        'SELECT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = %L AND table_name = %L AND column_name = %L)',
        v_new_schema, 'devices', 'firmware_version'
    ) INTO v_col_exists;

    IF NOT v_col_exists THEN
        RAISE EXCEPTION 'expand failed: devices.firmware_version not visible in new version schema %', v_new_schema;
    END IF;

    RAISE NOTICE 'OK: devices.firmware_version present in new version schema %', v_new_schema;
END $$;

-- Old clients (registering a device without firmware_version) must still
-- succeed: insert via the base table using only original columns and confirm
-- the backfill default applies.
INSERT INTO devices (serial, model) VALUES ('SN-COEXIST-TEST', 'sensor-a1')
ON CONFLICT (serial) DO NOTHING;

DO $$
DECLARE
    v_fw text;
BEGIN
    SELECT firmware_version INTO v_fw FROM devices WHERE serial = 'SN-COEXIST-TEST';
    IF v_fw IS DISTINCT FROM '0.0.0' THEN
        RAISE EXCEPTION 'backfill default failed: expected 0.0.0, got %', coalesce(v_fw, '<null>');
    END IF;
    RAISE NOTICE 'OK: old-schema insert backfilled firmware_version to 0.0.0';
END $$;

-- Cleanup the probe row so tests are idempotent.
DELETE FROM devices WHERE serial = 'SN-COEXIST-TEST';
