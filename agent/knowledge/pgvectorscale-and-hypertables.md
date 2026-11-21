# Tiger-native features: pgvectorscale and hypertables

## pgvectorscale (vector search)

pgvectorscale extends pgvector with StreamingDiskANN, a disk-resident
approximate-nearest-neighbor index based on Microsoft's DiskANN. It scales to
large vector sets better than in-memory HNSW because the index does not have to
fit entirely in RAM.

- Create the index: `CREATE INDEX ... USING diskann (embedding vector_cosine_ops)`
  for cosine distance (queried with the `<=>` operator). Other ops:
  `vector_l2_ops` (`<->`), `vector_ip_ops` (`<#>`).
- Statistical Binary Quantization (SBQ) shrinks the index for large datasets;
  tune it when the corpus grows into the hundreds of thousands of vectors.
- The extension is named `vectorscale`; it depends on `vector` (install with
  `CREATE EXTENSION vectorscale CASCADE`).

A RAG knowledge store is the natural use case: embed documents, index with
diskann, and query by similarity.

## Hypertables (time-series)

A TimescaleDB hypertable partitions a table into chunks along a time (or
otherwise increasing) dimension. It is built for high-ingest, append-mostly
time-series: metrics, IoT telemetry, logs. Benefits: chunk exclusion for
time-range queries, native compression, data retention policies, and continuous
aggregates.

### Hypertable constraint rule (important)

A hypertable's UNIQUE or PRIMARY KEY constraint MUST include the partitioning
column. This changes the identity model: you cannot keep a plain monotonic
single-column PK and also partition on time — the key becomes composite (e.g.
`(id, recorded_at)`), or the id is de-emphasized in favor of time-based access.
This is the central trade-off when considering a hypertable for a table that
has a meaningful single-column PK.

### When a hypertable fits — and when it does not

Fits: high-volume, time-stamped, append-only data queried by time range and
expired/compressed over time (e.g. `sensor_readings`).

Does NOT fit: a small, mostly-static table queried in full rather than by time
range — for example a RAG document store. Partitioning adds overhead with no
query benefit (similarity search has no time predicate for chunk exclusion), and
forcing a time column into the unique key defeats content-based deduplication.
For such a table, keep a plain table with a pgvectorscale index; do not convert
it to a hypertable. The right scaling lever there is SBQ/diskann tuning, not
partitioning.
