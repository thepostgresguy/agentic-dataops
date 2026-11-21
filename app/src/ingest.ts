// Ingest / read loop — demonstrates LIVE TRAFFIC during a migration.
//
// Inserts synthetic sensor_readings at a configurable low rate and reads them
// back, so the workshop can show ingestion never stops while a migration runs
// (the zero-downtime proof) and feed read/write latency to monitoring later.
//
// Reads DATABASE_URL at runtime (Tiger Cloud). Guarded behind a main() check so
// importing this module never starts the loop or touches a database.

import { createPrisma } from "./db";
import { ddMetric } from "./dd";

const RATE_PER_SEC = Number(process.env.INGEST_RATE_PER_SEC ?? "5");
const DURATION_SEC = Number(process.env.INGEST_DURATION_SEC ?? "0"); // 0 = forever
const METRICS = ["temperature", "humidity", "pressure", "battery"] as const;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function runIngestLoop(): Promise<void> {
  const prisma = createPrisma();
  const intervalMs = RATE_PER_SEC > 0 ? 1000 / RATE_PER_SEC : 1000;
  const stopAt = DURATION_SEC > 0 ? Date.now() + DURATION_SEC * 1000 : null;

  // Pick an existing device to attribute readings to.
  const device = await prisma.device.findFirst({ select: { id: true } });
  if (!device) {
    throw new Error("No devices found. Seed the database first (npm run seed).");
  }

  // eslint-disable-next-line no-console
  console.log(`[ingest] starting at ~${RATE_PER_SEC}/s (duration=${DURATION_SEC || "∞"}s)`);

  try {
    while (stopAt === null || Date.now() < stopAt) {
      const writeStart = Date.now();
      await prisma.sensorReading.create({
        data: {
          deviceId: device.id,
          metric: METRICS[Math.floor(Math.random() * METRICS.length)],
          value: (Math.random() * 100).toFixed(3),
        },
      });
      ddMetric("app.ingest.write_latency_ms", Date.now() - writeStart);

      const readStart = Date.now();
      await prisma.sensorReading.findFirst({ orderBy: { recordedAt: "desc" } });
      ddMetric("app.ingest.read_latency_ms", Date.now() - readStart);
      ddMetric("app.ingest.rate_per_sec", RATE_PER_SEC);

      await sleep(intervalMs);
    }
  } finally {
    await prisma.$disconnect();
  }
}

// Only run when invoked directly (never on import).
if (require.main === module) {
  runIngestLoop().catch((err) => {
    // eslint-disable-next-line no-console
    console.error("[ingest] error:", err);
    process.exit(1);
  });
}

export { runIngestLoop };
