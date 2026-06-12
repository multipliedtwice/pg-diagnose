#!/usr/bin/env bash

emit_sugg_rules_catalog() {
  cat <<RULES_CATALOG_SQL
\echo '-- rule:stale-statistics'
INSERT INTO sugg
SELECT
  'HIGH', 'HIGH', 'Stale or missing planner statistics',
  NULL,
  x.fqname,
  'ANALYZE ' || x.fqname_q || ';',
  CASE WHEN x.never_analyzed
       THEN 'never analyzed (reltuples = -1): the planner guesses row counts from page counts'
       ELSE 'a large fraction of rows changed since the last ANALYZE' END,
  'n_live_tup=' || x.n_live_tup
    || ' n_mod_since_analyze=' || x.n_mod_since_analyze
    || ' reltuples=' || x.reltuples
    || ' last_analyzed=' || coalesce(x.last_analyzed::text, 'never')
    || ' total_size=' || x.size,
  'run ANALYZE, then re-run $0 --mode=suggestions — other suggestions may change',
  5
FROM (
  SELECT
    s.schemaname || '.' || s.relname AS fqname,
    quote_ident(s.schemaname) || '.' || quote_ident(s.relname) AS fqname_q,
    s.n_live_tup,
    s.n_mod_since_analyze,
    c.reltuples::bigint AS reltuples,
    greatest(s.last_analyze, s.last_autoanalyze) AS last_analyzed,
    pg_size_pretty(pg_total_relation_size(s.relid)) AS size,
    (c.reltuples < 0) AS never_analyzed
  FROM pg_stat_user_tables s
  JOIN pg_class c ON c.oid = s.relid
  WHERE s.schemaname NOT LIKE 'pg\_temp%'
    AND pg_relation_size(s.relid) > 10 * 1024 * 1024
    AND (c.reltuples < 0
         OR s.n_mod_since_analyze > greatest(0.2 * s.n_live_tup, 10000))
) x;

\echo '-- rule:vector-column-statistics'
INSERT INTO sugg
SELECT
  'MEDIUM', 'HIGH', 'Expensive ANALYZE from statistics on vector columns',
  NULL,
  x.fqname || '.' || x.attname,
  'ALTER TABLE ' || x.fqname_q || ' ALTER COLUMN ' || quote_ident(x.attname) || ' SET STATISTICS 0;'
    || chr(10) || 'ANALYZE ' || x.fqname_q || ';',
  NULL,
  'type=' || x.typname
    || ' avg_analyze_ms=' || coalesce(x.avg_ms::bigint::text, 'n/a')
    || ' analyzes=' || x.analyzes
    || ' table_size=' || x.size,
  'ANALYZE the table, then re-run $0 --only=tables and compare ANALYZE cost',
  18
FROM (
  SELECT n.nspname || '.' || c.relname AS fqname,
         quote_ident(n.nspname) || '.' || quote_ident(c.relname) AS fqname_q,
         a.attname,
         ty.typname,
         (st.total_analyze_time + st.total_autoanalyze_time)
           / NULLIF(st.analyze_count + st.autoanalyze_count, 0) AS avg_ms,
         coalesce(st.analyze_count + st.autoanalyze_count, 0) AS analyzes,
         pg_size_pretty(pg_total_relation_size(c.oid)) AS size
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid AND c.relkind IN ('r', 'm')
  JOIN pg_namespace n ON n.oid = c.relnamespace
    AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  JOIN pg_type ty ON ty.oid = a.atttypid AND ty.typname IN ('vector', 'halfvec', 'sparsevec')
  LEFT JOIN pg_stat_user_tables st ON st.relid = c.oid
  WHERE NOT a.attisdropped
    AND a.attnum > 0
    AND a.attstattarget IS DISTINCT FROM 0
    AND pg_total_relation_size(c.oid) > 100 * 1024 * 1024
) x
WHERE x.avg_ms > 60000 OR x.analyzes = 0;

\echo '-- rule:autoanalyze-never-fires'
INSERT INTO sugg
SELECT
  'HIGH', 'MEDIUM', 'Autoanalyze has never run on a write-heavy table',
  NULL,
  x.fqname,
  'ALTER TABLE ' || x.fqname_q || ' SET (autovacuum_analyze_scale_factor = 0.02, autovacuum_vacuum_scale_factor = 0.05);',
  'with the default scale factor this table needs roughly ' || x.threshold || ' modified rows between runs',
  'writes=' || x.writes
    || ' autoanalyze_count=0'
    || ' n_mod_since_analyze=' || x.n_mod
    || ' approx_threshold=' || x.threshold
    || ' last_analyze=' || coalesce(x.last_a::text, 'never')
    || ' total_size=' || x.size,
  're-run $0 --only=tables after a few days and confirm autoanalyze_count is increasing',
  19
FROM (
  SELECT
    s.schemaname || '.' || s.relname AS fqname,
    quote_ident(s.schemaname) || '.' || quote_ident(s.relname) AS fqname_q,
    s.n_tup_ins + s.n_tup_upd + s.n_tup_del AS writes,
    s.n_mod_since_analyze AS n_mod,
    (0.1 * s.n_live_tup + 50)::bigint AS threshold,
    greatest(s.last_analyze, s.last_autoanalyze) AS last_a,
    pg_size_pretty(pg_total_relation_size(s.relid)) AS size
  FROM pg_stat_user_tables s
  WHERE s.schemaname NOT LIKE 'pg\_temp%'
    AND s.autoanalyze_count = 0
    AND s.n_tup_ins + s.n_tup_upd + s.n_tup_del > 10000
    AND pg_total_relation_size(s.relid) > 100 * 1024 * 1024
) x;

\echo '-- rule:dead-tuples'
INSERT INTO sugg
SELECT
  CASE WHEN x.dead_pct > 50 THEN 'HIGH' ELSE 'MEDIUM' END,
  'MEDIUM',
  'Dead tuple bloat slowing scans',
  NULL,
  x.fqname,
  'VACUUM (ANALYZE) ' || x.fqname_q || ';',
  'durable fix if it recurs: ALTER TABLE ' || x.fqname_q || ' SET (autovacuum_vacuum_scale_factor = 0.02);',
  'n_dead_tup=' || x.n_dead_tup
    || ' dead_pct=' || x.dead_pct
    || ' last_autovacuum=' || coalesce(x.last_autovacuum::text, 'never')
    || ' total_size=' || x.size,
  're-run $0 --only=tables after VACUUM; if dead_pct climbs back within days, tune per-table autovacuum',
  35
FROM (
  SELECT
    s.schemaname || '.' || s.relname AS fqname,
    quote_ident(s.schemaname) || '.' || quote_ident(s.relname) AS fqname_q,
    s.n_dead_tup,
    round(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 1) AS dead_pct,
    s.last_autovacuum,
    pg_size_pretty(pg_total_relation_size(s.relid)) AS size
  FROM pg_stat_user_tables s
  WHERE s.schemaname NOT LIKE 'pg\_temp%'
    AND s.n_dead_tup > 10000
    AND pg_relation_size(s.relid) > 10 * 1024 * 1024
    AND 100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0) > 30
) x;

\echo '-- rule:wal-buffers-saturation'
INSERT INTO sugg
SELECT
  'MEDIUM', 'LOW', 'WAL buffers saturating on insert',
  NULL, 'cluster', NULL, NULL,
  'wal_buffers_full=' || w.wal_buffers_full
    || ' wal_records=' || w.wal_records
    || ' ratio=' || round(w.wal_buffers_full::numeric / NULLIF(w.wal_records, 0), 2)
    || ' wal_generated=' || pg_size_pretty(w.wal_bytes::bigint)
    || ' wal_buffers=' || current_setting('wal_buffers'),
  'run a full $0 pass and compare the in-window wal_buffers_full delta against the wal_records delta',
  45
FROM pg_stat_wal w
WHERE w.wal_buffers_full > 0.5 * w.wal_records;

\echo '-- rule:fk-missing-index'
INSERT INTO sugg
SELECT
  'MEDIUM',
  CASE WHEN bool_or(coalesce(f.plan_refs, 0) > 0) THEN 'HIGH'
       WHEN bool_or(f.parent_del > 0
                    AND f.del_action IN ('CASCADE', 'SET NULL', 'SET DEFAULT', 'RESTRICT')) THEN 'MEDIUM'
       WHEN '${HAS_PGSS}' <> 't' THEN 'MEDIUM'
       ELSE 'LOW' END,
  'Missing index on foreign key',
  NULL,
  f.child_table,
  string_agg(f.ddl, chr(10) ORDER BY f.conname),
  CASE WHEN bool_or(f.soft)
       THEN 'parents marked (soft-delete) in evidence are rarely hard-deleted — for those, index only if the column is used in joins'
       ELSE NULL END,
  string_agg(f.conname || ' → ' || f.parent
             || CASE WHEN f.soft THEN ' (soft-delete parent)' ELSE '' END
             || ' on_delete=' || f.del_action
             || ' parent_del=' || f.parent_del
             || ' plan_refs=' || coalesce(f.plan_refs::text, 'n/a')
             || ' text_refs=' || coalesce(f.pgss_refs::text, 'n/a'),
             '; ' ORDER BY f.conname)
    || ' child_size=' || max(f.child_size)
    || ' child_writes=' || max(f.child_writes),
  'EXPLAIN (ANALYZE, BUFFERS) a join on these columns; re-run $0 --only=indexes after creating',
  30
FROM (
  SELECT
    n.nspname || '.' || cl.relname AS child_table,
    c.conname,
    rn.nspname || '.' || rcl.relname AS parent,
    CASE c.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
         WHEN 'd' THEN 'SET DEFAULT' WHEN 'r' THEN 'RESTRICT'
         ELSE 'NO ACTION' END AS del_action,
    coalesce(pst.n_tup_del, 0) AS parent_del,
    ${FK_REFS_SQL} AS pgss_refs,
    ${FK_PLANREFS_SQL} AS plan_refs,
    'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
      || quote_ident(pg_temp.idx_name(c.conname || '_idx'))
      || ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(cl.relname)
      || ' (' ||
      (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY x.ord)
         FROM unnest(c.conkey) WITH ORDINALITY AS x(attnum, ord)
         JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum)
      || ');' AS ddl,
    pg_size_pretty(pg_relation_size(c.conrelid)) AS child_size,
    coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) AS child_writes,
    EXISTS (
      SELECT 1 FROM pg_attribute pa
      WHERE pa.attrelid = c.confrelid
        AND pa.attname = 'deletedAt'
        AND NOT pa.attisdropped
    ) AS soft
  FROM pg_constraint c
  JOIN pg_class cl ON cl.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = cl.relnamespace
  JOIN pg_class rcl ON rcl.oid = c.confrelid
  JOIN pg_namespace rn ON rn.oid = rcl.relnamespace
  LEFT JOIN pg_stat_user_tables st ON st.relid = c.conrelid
  LEFT JOIN pg_stat_user_tables pst ON pst.relid = c.confrelid
  CROSS JOIN LATERAL (
    SELECT a.attname AS colname
    FROM unnest(c.conkey) WITH ORDINALITY AS x(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum
    ORDER BY x.ord
    LIMIT 1
  ) fc
  WHERE c.contype = 'f'
    AND (pg_relation_size(c.conrelid) > 10 * 1024 * 1024
         OR coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) > 100)
    AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      JOIN pg_class ic ON ic.oid = i.indexrelid
      JOIN pg_am am ON am.oid = ic.relam AND am.amname IN ('btree', 'hash')
      WHERE i.indrelid = c.conrelid
        AND i.indisvalid
        AND i.indisready
        AND i.indpred IS NULL
        AND i.indnkeyatts >= cardinality(c.conkey)
        AND (i.indkey::smallint[])[0:cardinality(c.conkey) - 1] @> c.conkey::smallint[]
    )
) f
GROUP BY f.child_table;
RULES_CATALOG_SQL
}