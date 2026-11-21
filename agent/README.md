# agent — the DB-consultant (Strands + Amazon Nova Pro on AgentCore)

The AI data expert for the demo. It reviews migration SQL (the new Liquibase
changesets in a PR, or an option pasted into `migration-test`) and
**advises**: flags hazards (e.g. the int4->bigint `ALTER COLUMN ... TYPE` that
forces an ACCESS EXCLUSIVE full-table rewrite on the ~2.1B-row `sensor_readings`
table), gives a verdict, and recommends safe zero-downtime alternatives
(shadow-column/backfill, or the TimescaleDB hypertable option). It recommends;
the human decides. It never applies migrations and never writes to a database.

## Two modes

- **Tool-less** (`migration-review`): one prompt in, one answer out. No database.
- **Agentic** (`migration-test`): the request carries `inspect_dsn`, a read-only
  DSN for the run's EPHEMERAL service. The agent gets two tools,
  `describe_table` and `run_readonly_query`, and loops (reason, call a tool,
  observe, repeat) until it is ready to answer. Guardrails: dedicated `agent_ro`
  role (SELECT only, `default_transaction_read_only`), `READ ONLY` transaction
  per call, 5 s statement timeout, 50-row cap, one statement per call, 12-call
  budget. Every step is streamed back as `{"trace": ...}` and shown in the run
  report's "Agent trace". See `docs/workshop-abstract.md` for what "agentic
  workload" means here.

## Knowledge base (RAG)

Every request is grounded in a vector store (`rag_documents` on the private RAG
Tiger service). Retrieval is best-effort: if the store is unreachable the agent
answers from the model alone.

- `knowledge/*.md` — curated playbooks (int4→bigint, lock/rewrite hazards,
  zero-downtime principles, hypertables, NOT NULL columns).
- `knowledge/decisions/` — **human feedback**. After a review and test, copy
  `TEMPLATE.md` to `<yyyy-mm-dd>-<slug>.md`, fill it in, commit, and run the
  `rag-ingest` workflow. Future reviews retrieve these decisions.
- `ingest.py` / `ingest.Dockerfile` — embeds the corpus (Amazon Titan Text
  Embeddings v2, 1024 dims) and upserts it by content hash.
- `retrieval.py` — fetches the most relevant passages for a migration's SQL.

## Files

- `consultant.py` — the agent: system prompt (the DB-expert persona), plus the
  tools prompt in agentic mode. Model from `BEDROCK_MODEL_ID` (default Nova Pro).
- `db_tools.py` — the read-only tools and their guardrails.
- `cli.py` — local test harness (no AgentCore): analyze a migration file.
- `app.py` — the AgentCore Runtime entrypoint (`@app.entrypoint` handler). Builds
  a fresh agent per request and streams answer text plus trace events.
- `Dockerfile` — image AgentCore runs.
- `requirements.txt` — pinned deps.

## Test locally (before deploying)

Needs AWS credentials with `bedrock:InvokeModel` for the model, region
`us-east-1`, and the model enabled in Bedrock model access.

```bash
pip install -r agent/requirements.txt
export BEDROCK_MODEL_ID=amazon.nova-pro-v1:0
python -m agent.cli infra/db/app/changesets/001_baseline.sql
```

Try it against the baseline (should read SAFE — just CREATE TABLEs), then
against `infra/db/app/changesets/002_sensor_readings_id_bigint.sql` or the unsafe
example (`migrations/unsafe-examples/0099_unsafe_type_change.sql`), which should
read UNSAFE with the rewrite hazard and alternatives.

## Deploy (AgentCore)

1. Build + push the image to the agent ECR repo
   (`agentic-dataops/agent`), tagged with the git SHA.
2. Apply the runtime: `tofu apply -var agent_image_tag=<sha>` (see
   `infra/tofu/agent.tf`). The runtime is created only when a tag is set.

Model id must be enabled in `us-east-1` Bedrock model access before invoke.
