// Prisma client factory + search_path helper.
//
// The connection comes from DATABASE_URL (a Tiger Cloud DSN at runtime — never
// hardcoded, never localhost). To demonstrate reading the OLD vs NEW table
// shape during a zero-downtime migration, the app can set its connection
// search_path via APP_SCHEMA_VERSION: flipping that env var points the same app
// at a different schema (e.g. a view presenting the old or new shape) against
// the same physical database. One env change = old vs new reader.

import { PrismaClient } from "@prisma/client";

export function getDatabaseUrl(): string {
  const url = process.env.DATABASE_URL;
  if (!url) {
    throw new Error(
      "DATABASE_URL is not set. Provide the Tiger Cloud DSN (from AWS Secrets " +
        "Manager agentic-dataops/app/database-url, or a local .env). No localhost.",
    );
  }
  return url;
}

// Build a DSN with the search_path set to the requested schema version, so the
// app reads through the chosen (old/new) version schema during a migration.
function urlWithSchema(baseUrl: string, schema: string): string {
  const u = new URL(baseUrl);
  // Postgres honors the `options` / `search_path` via the `schema` query param
  // in many drivers; for node-postgres style DSNs we pass search_path through
  // the `options` parameter.
  u.searchParams.set("options", `-c search_path=${schema}`);
  return u.toString();
}

export function createPrisma(): PrismaClient {
  const schema = process.env.APP_SCHEMA_VERSION?.trim();
  const baseUrl = getDatabaseUrl();
  const datasourceUrl =
    schema && schema !== "public" ? urlWithSchema(baseUrl, schema) : baseUrl;

  return new PrismaClient({
    datasourceUrl,
    log: ["warn", "error"],
  });
}
