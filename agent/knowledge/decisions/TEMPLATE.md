# Migration decision: <short title>

<!--
  HUMAN FEEDBACK / WORKED EXAMPLE for the RAG knowledge base.
  Copy this file to agent/knowledge/decisions/<yyyy-mm-dd>-<slug>.md, fill it in,
  commit, and run the rag-ingest workflow (incremental). Future migration
  reviews retrieve these, so the agent learns from what YOU actually decided —
  not just generic Postgres docs. One decision per file. Keep it concrete.
-->

- **Date:** <yyyy-mm-dd>
- **Table(s):** <e.g. sensor_readings>
- **Change reviewed:** <one line — what the schema change was>

## The migration SQL that was reviewed

```sql
-- the naive SQL Prisma generated (what the agent analyzed)
```

## Verdict

<SAFE online | UNSAFE — needed a zero-downtime approach>. <one or two lines on
why: lock level, rewrite yes/no, blast radius observed.>

## Chosen approach

<Name of the approach we actually went with, and the key steps — the SQL or the
sequence. This is the "do it this way" example the agent should reuse.>

```sql
-- the approach's actual SQL / steps, if applicable
```

## Rationale

<Why this approach over the alternatives the agent proposed. What the tradeoff
was, what we cared about (e.g. ingestion must not stop), what we rejected and
why. This is the reasoning future reviews should learn from.>

## Outcome (optional)

<What happened when we ran it — lock/hold time, duration, any surprise. Real
evidence makes this a stronger example.>
