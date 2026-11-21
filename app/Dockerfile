# Containerized IoT telemetry demo app (TypeScript + Prisma).
# No local DB — connects to a Tiger Cloud service via DATABASE_URL at runtime.
# Pinned base image.

FROM public.ecr.aws/docker/library/node:22-bookworm-slim

WORKDIR /app

# Prisma's query engine needs OpenSSL at runtime. Bookworm ships OpenSSL 3, and
# the slim image omits it — install it (and ca-certificates for TLS to Tiger).
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install deps first (layer cache).
COPY package.json ./
RUN npm install --omit=dev=false

# Prisma schema + app source.
COPY prisma ./prisma
COPY tsconfig.json ./
COPY src ./src

# Generate the Prisma client and build TypeScript.
RUN npx prisma generate && npm run build

# Non-root.
USER node

# Default: run the web server (what ECS/ALB route and health-check to).
# Override the command for other tasks:
#   npx prisma migrate deploy    (apply migrations)
#   node dist/seed.js            (seed)
#   node dist/ingest.js          (ingest loop — live traffic during migration)
EXPOSE 8080
ENTRYPOINT ["node", "dist/server.js"]
