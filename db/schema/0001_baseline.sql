-- Baseline schema for the IoT telemetry demo. Applied once to a fresh Tiger
-- Cloud dev service before Prisma migrations are applied. Represents the "existing
-- production" shape whose sensor_readings.id (int4) PK is about to overflow at
-- ~2.1 billion rows. Fully coded; applied by CI, never by hand.

CREATE TABLE IF NOT EXISTS devices (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    serial        text        NOT NULL UNIQUE,
    model         text        NOT NULL,
    registered_at timestamptz NOT NULL DEFAULT now()
);

-- The hot table. NOTE: id is intentionally int4 (integer) -- this is the
-- overflow hazard the workshop migrates to bigint with zero downtime.
CREATE TABLE IF NOT EXISTS sensor_readings (
    id          integer     GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id   bigint      NOT NULL REFERENCES devices (id),
    metric      text        NOT NULL,
    value       numeric     NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sensor_readings_device_id_idx ON sensor_readings (device_id);
CREATE INDEX IF NOT EXISTS sensor_readings_recorded_at_idx ON sensor_readings (recorded_at);

-- Illustrative billing/usage table: money is ALWAYS NUMERIC(15,2), never cents.
CREATE TABLE IF NOT EXISTS device_usage_charges (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id   bigint      NOT NULL REFERENCES devices (id),
    amount      numeric(15,2) NOT NULL CHECK (amount >= 0),
    charged_at  timestamptz NOT NULL DEFAULT now()
);
