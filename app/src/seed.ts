// Parameterized seed harness.
//
// The SAME code seeds the ~1,000,000-row LIVE demo boundary and the one-off
// ~1,000,000,000-row RECORDED headline run (charter rule 11) — only the inputs
// differ:
//   SEED_ROWS       number of sensor_readings to insert
//   SEED_DEVICES    number of devices to ensure exist
//   SEED_SEQ_START  optional: reset sensor_readings.id sequence to near this
//                   value. Set to just under the int4 ceiling (2147483647) so
//                   the overflow is genuine/imminent even at the 1M boundary.
//
// Reads DATABASE_URL at runtime (Tiger Cloud). Guarded behind main() so import
// never seeds. Batched inserts via executeRawUnsafe generate_series for speed.
//
// COST (charter rule 11): never seed billions on the parallel bake-off; the 1B
// run is a one-off on a single service, torn down after. Live demo uses ~1M.

import { createPrisma } from "./db";

const SEED_ROWS = Number(process.env.SEED_ROWS ?? "1000000");
const SEED_DEVICES = Number(process.env.SEED_DEVICES ?? "1000");
const SEED_SEQ_START = process.env.SEED_SEQ_START?.trim();
const BATCH = 50_000;

async function seed(): Promise<void> {
  const prisma = createPrisma();
  try {
    // 1. Devices.
    // eslint-disable-next-line no-console
    console.log(`[seed] ensuring ${SEED_DEVICES} devices...`);
    await prisma.$executeRawUnsafe(
      `INSERT INTO devices (serial, model)
       SELECT 'SN-' || lpad(g::text, 8, '0'),
              (ARRAY['sensor-a1','sensor-b2','gateway-g3'])[floor(random()*3+1)]
       FROM generate_series(1, $1) AS g
       ON CONFLICT (serial) DO NOTHING`,
      SEED_DEVICES,
    );

    // 2. Optionally reset the int4 id sequence near the overflow boundary so
    //    the hazard is real at a small row count. identity column sequence is
    //    pg_get_serial_sequence('sensor_readings','id').
    if (SEED_SEQ_START) {
      // eslint-disable-next-line no-console
      console.log(`[seed] resetting sensor_readings.id sequence to ${SEED_SEQ_START}`);
      await prisma.$executeRawUnsafe(
        `SELECT setval(pg_get_serial_sequence('sensor_readings','id'), $1, false)`,
        Number(SEED_SEQ_START),
      );
    }

    // 3. sensor_readings, batched.
    // eslint-disable-next-line no-console
    console.log(`[seed] inserting ${SEED_ROWS} sensor_readings in batches of ${BATCH}...`);
    let remaining = SEED_ROWS;
    while (remaining > 0) {
      const n = Math.min(BATCH, remaining);
      await prisma.$executeRawUnsafe(
        `INSERT INTO sensor_readings (device_id, metric, value, recorded_at)
         SELECT (random()*($2-1)+1)::bigint,
                (ARRAY['temperature','humidity','pressure','battery'])[floor(random()*4+1)],
                round((random()*100)::numeric, 3),
                now() - (random() * interval '30 days')
         FROM generate_series(1, $1)`,
        n,
        SEED_DEVICES,
      );
      remaining -= n;
      // eslint-disable-next-line no-console
      console.log(`[seed]   ${SEED_ROWS - remaining}/${SEED_ROWS}`);
    }

    // eslint-disable-next-line no-console
    console.log("[seed] done.");
  } finally {
    await prisma.$disconnect();
  }
}

if (require.main === module) {
  seed().catch((err) => {
    // eslint-disable-next-line no-console
    console.error("[seed] error:", err);
    process.exit(1);
  });
}

export { seed };
