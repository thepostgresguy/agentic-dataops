-- Normalized structural signature of the demo tables (columns, indexes,
-- constraints). Version-agnostic (catalog queries, no pg_dump), so the same file
-- can be run against the app DB and an ephemeral clone and the outputs diffed.
-- Usage: psql "$DSN" -qAt -f scripts/schema_signature.sql
SELECT line FROM (
  SELECT 'column|' || c.relname || '|' || a.attname || '|' ||
         format_type(a.atttypid, a.atttypmod) ||
         '|notnull=' || a.attnotnull ||
         '|identity=' || coalesce(nullif(a.attidentity::text, ''), '-') ||
         '|default=' || coalesce(pg_get_expr(d.adbin, d.adrelid), '-') AS line
    FROM pg_attribute a
    JOIN pg_class c ON c.oid = a.attrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
   WHERE n.nspname = 'public' AND c.relkind = 'r'
     AND c.relname IN ('devices', 'sensor_readings', 'device_usage_charges')
     AND a.attnum > 0 AND NOT a.attisdropped
  UNION ALL
  SELECT 'index|' || tablename || '|' || indexname || '|' || indexdef
    FROM pg_indexes
   WHERE schemaname = 'public'
     AND tablename IN ('devices', 'sensor_readings', 'device_usage_charges')
  UNION ALL
  SELECT 'constraint|' || conrelid::regclass::text || '|' || conname || '|' ||
         pg_get_constraintdef(oid)
    FROM pg_constraint
   WHERE connamespace = 'public'::regnamespace
     AND conrelid::regclass::text IN ('devices', 'sensor_readings', 'device_usage_charges')
) s
ORDER BY line;
