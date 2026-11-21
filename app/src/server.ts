// HTTP server (Fastify) for the IoT telemetry demo app.
//
// This is what ECS Fargate runs and the ALB routes/health-checks to. Endpoints:
//   GET /health            - liveness/readiness (checks DB connectivity)
//   GET /stats             - THE overflow gauge: current sensor_readings.id max
//                            vs the int4 ceiling (2,147,483,647). The live visual
//                            for the workshop — watch it climb toward overflow.
//   GET /devices           - list devices (paginated)
//   GET /readings/recent   - most recent sensor readings
//
// Connection via DATABASE_URL (Tiger Cloud) through src/db.ts. The server
// binds 0.0.0.0 so the ALB can reach it in the container.

import Fastify from "fastify";
import { createPrisma } from "./db";
import { ddMetric } from "./dd";

const INT4_MAX = 2147483647; // the int4 ceiling sensor_readings.id is approaching
const PORT = Number(process.env.PORT ?? "8080");
const HOST = "0.0.0.0";

const app = Fastify({ logger: true });
const prisma = createPrisma();

// Front page — a generic branded "Overflow" landing page: an app shell with
// title, nav and a short description. Intentionally NOT coupled to the database
// or the int4 gauge; the live data endpoints below (/stats, /devices,
// /readings/recent) are linked from the nav and can be wired into the page
// later.
app.get("/", async (_req, reply) => {
  reply.type("text/html");
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Overflow</title>
  <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
           background:#0b1020; color:#e6e9f0; min-height:100vh; display:flex; flex-direction:column; }
    header { display:flex; align-items:center; justify-content:space-between;
             padding:1.1rem 1.75rem; border-bottom:1px solid #22304f; }
    .brand { display:flex; align-items:center; gap:.6rem; font-weight:700; font-size:1.15rem; }
    .brand .mark { font-size:1.4rem; }
    nav { display:flex; gap:1.25rem; }
    nav a { color:#9ec5ff; text-decoration:none; font-size:.95rem; }
    nav a:hover { color:#e6e9f0; }
    main { flex:1; display:flex; align-items:center; justify-content:center; padding:2rem; }
    .hero { width:min(680px,92vw); text-align:center; }
    h1 { margin:0 0 .5rem; font-size:2.4rem; }
    .sub { color:#8b96ad; margin:0 auto 2rem; max-width:48ch; line-height:1.5; }
    .actions { display:flex; gap:.75rem; justify-content:center; flex-wrap:wrap; }
    .btn { padding:.65rem 1.25rem; border-radius:10px; text-decoration:none; font-weight:600; font-size:.95rem; }
    .btn.primary { background:#2dd4bf; color:#07241f; }
    .btn.ghost { border:1px solid #22304f; color:#e6e9f0; }
    .btn:hover { opacity:.9; }
    footer { padding:1.1rem 1.75rem; border-top:1px solid #22304f; color:#5c6680; font-size:.8rem; text-align:center; }
    code { color:#9ec5ff; }
  </style>
</head>
<body>
  <header>
    <div class="brand"><span class="mark">🌊</span><span>Overflow</span></div>
    <nav>
      <a href="/stats">Stats</a>
      <a href="/devices">Devices</a>
      <a href="/readings/recent">Readings</a>
      <a href="/health">Health</a>
    </nav>
  </header>
  <main>
    <div class="hero">
      <h1>Overflow</h1>
      <p class="sub">IoT telemetry on Tiger Cloud. Devices stream sensor readings;
        this app serves them and exposes the data through a small JSON API.</p>
      <div class="actions">
        <a class="btn primary" href="/stats">View stats</a>
        <a class="btn ghost" href="/devices">Browse devices</a>
      </div>
    </div>
  </main>
  <footer>SRE Day NY 2026 · <code>overflow.thepostgresguy.com</code></footer>
</body>
</html>`;
});

// Liveness/readiness — ALB health check target. Verifies DB connectivity.
app.get("/health", async (_req, reply) => {
  try {
    await prisma.$queryRaw`SELECT 1`;
    return { status: "ok", db: "up" };
  } catch (err) {
    reply.code(503);
    return { status: "degraded", db: "down", error: String(err) };
  }
});

// The overflow gauge. Shows how close sensor_readings.id is to int4 overflow.
app.get("/stats", async () => {
  // The hazard is about the SEQUENCE (next id to be assigned), not just the max
  // present row — report both. The sequence value is the real overflow signal.
  const seqRows = await prisma.$queryRawUnsafe<{ last_value: bigint | null }[]>(
    `SELECT last_value FROM pg_sequences
     WHERE schemaname = current_schema()
       AND sequencename = (
         SELECT pg_get_serial_sequence('sensor_readings','id')
       )::regclass::text`,
  ).catch(() => [] as { last_value: bigint | null }[]);

  const maxRow = await prisma.sensorReading.aggregate({ _max: { id: true } });
  // sensor_readings.id is BigInt in the Prisma client; the gauge math is in
  // number space (values are <= ~2.1B, well within Number.MAX_SAFE_INTEGER).
  const maxId = maxRow._max.id != null ? Number(maxRow._max.id) : 0;
  const seqLast = seqRows[0]?.last_value != null ? Number(seqRows[0].last_value) : maxId;

  const current = Math.max(maxId, seqLast);
  const headroom = INT4_MAX - current;
  const pctUsed = (current / INT4_MAX) * 100;

  ddMetric("app.overflow.pct_used", pctUsed);
  ddMetric("app.overflow.headroom", headroom);

  return {
    column: "sensor_readings.id",
    type: "int4",
    int4_ceiling: INT4_MAX,
    current_value: current,
    headroom,
    pct_used: Number(pctUsed.toFixed(4)),
    overflow_imminent: headroom < 1_000_000,
  };
});

// List devices (paginated).
app.get<{ Querystring: { limit?: string; offset?: string } }>(
  "/devices",
  async (req) => {
    const limit = Math.min(Number(req.query.limit ?? "50"), 500);
    const offset = Number(req.query.offset ?? "0");
    const devices = await prisma.device.findMany({
      take: limit,
      skip: offset,
      orderBy: { id: "asc" },
    });
    // BigInt isn't JSON-serializable by default — stringify ids.
    return devices.map((d) => ({ ...d, id: d.id.toString() }));
  },
);

// Most recent sensor readings.
app.get<{ Querystring: { limit?: string } }>(
  "/readings/recent",
  async (req) => {
    const limit = Math.min(Number(req.query.limit ?? "20"), 200);
    const readings = await prisma.sensorReading.findMany({
      take: limit,
      orderBy: { recordedAt: "desc" },
    });
    return readings.map((r) => ({
      ...r,
      deviceId: r.deviceId.toString(),
      value: r.value.toString(),
    }));
  },
);

async function main(): Promise<void> {
  await app.listen({ port: PORT, host: HOST });
}

if (require.main === module) {
  main().catch((err) => {
    app.log.error(err);
    process.exit(1);
  });
}

export { app };
