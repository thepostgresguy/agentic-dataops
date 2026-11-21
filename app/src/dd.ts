// Datadog instrumentation seam — INERT by default.
//
// Full Datadog monitoring (dashboards, custom metrics, migration-phase Events,
// the rollback-signal gate) is a DEFERRED later phase. These are no-op stubs so
// the app has the seams to attach to later without reshaping anything. Nothing
// here requires Datadog credentials, and DD_ENABLED defaults to false.

const DD_ENABLED = (process.env.DD_ENABLED ?? "false").toLowerCase() === "true";

export function ddMetric(name: string, value: number, tags: string[] = []): void {
  if (!DD_ENABLED) return;
  // Phase-3 (monitoring): emit to Datadog (dogstatsd / API). Stub for now.
  // eslint-disable-next-line no-console
  console.debug(`[dd] metric ${name}=${value} ${tags.join(",")}`);
}

export function ddEvent(title: string, text: string): void {
  if (!DD_ENABLED) return;
  // Phase-3 (monitoring): emit a Datadog Event (e.g. app-version switch). Stub.
  // eslint-disable-next-line no-console
  console.debug(`[dd] event ${title}: ${text}`);
}
