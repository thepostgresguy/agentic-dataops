-- Deterministic seed data for the IoT telemetry demo so migration correctness
-- and performance checks run against a non-trivial dataset. Applied by CI.
--
-- NOTE: this seeds a modest baseline. The candidate evaluation harness is what
-- drives sensor_readings toward the int4 overflow boundary (~2.1B) on each
-- candidate's own Tiger Cloud service; seeding 2.1B rows here would be wasteful.

INSERT INTO devices (serial, model)
SELECT
    'SN-' || lpad(g::text, 8, '0'),
    (ARRAY['sensor-a1', 'sensor-b2', 'gateway-g3'])[floor(random() * 3 + 1)]
FROM generate_series(1, 1000) AS g
ON CONFLICT (serial) DO NOTHING;

INSERT INTO sensor_readings (device_id, metric, value, recorded_at)
SELECT
    (random() * 999 + 1)::bigint,
    (ARRAY['temperature', 'humidity', 'pressure', 'battery'])[floor(random() * 4 + 1)],
    round((random() * 100)::numeric, 3),
    now() - (random() * interval '30 days')
FROM generate_series(1, 100000);

INSERT INTO device_usage_charges (device_id, amount, charged_at)
SELECT
    (random() * 999 + 1)::bigint,
    round((random() * 500)::numeric, 2),   -- money as NUMERIC(15,2)
    now() - (random() * interval '30 days')
FROM generate_series(1, 5000);
