#!/usr/bin/env bash

phase_indexes() {
  echo
  echo "╔═══════════════════════════════════════════════════════╗"
  echo "║   Index advice (evidence: static + plan estimates)    ║"
  echo "║   candidates with evidence — not ready-to-run DDL     ║"
  echo "╚═══════════════════════════════════════════════════════╝"

  local STATS_DAYS
  STATS_DAYS="$(psql_get "
  SELECT extract(day FROM now() - coalesce(
    (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()),
    (SELECT min(stats_reset) FROM pg_stat_io),
    now()))::int;" "")"
  if [[ "$STATS_DAYS" =~ ^[0-9]+$ && "$STATS_DAYS" -lt 14 ]]; then
    echo
    echo "   ⚠  stats window covers at most ${STATS_DAYS} day(s) — lifetime evidence below"
    echo "      (zero-scan indexes especially) is weak; do not act on it yet."
  fi

  run_section "unindexed FK columns (child > 10MB or > 100 writes; soft-delete parents annotated)" "
  SELECT
    n.nspname || '.' || cl.relname AS child_table,
    c.conname AS fk_constraint,
    (SELECT string_agg(a.attname, ', ' ORDER BY x.ord)
       FROM unnest(c.conkey) WITH ORDINALITY AS x(attnum, ord)
       JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum) AS fk_columns,
    rn.nspname || '.' || rcl.relname AS referenced_table,
    pg_size_pretty(pg_relation_size(c.conrelid)) AS child_size,
    coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) AS child_writes,
    CASE WHEN EXISTS (
           SELECT 1 FROM pg_attribute pa
           WHERE pa.attrelid = c.confrelid
             AND pa.attname = 'deletedAt'
             AND NOT pa.attisdropped)
         THEN 'parent soft-deletes — RI benefit unlikely; index only if joined on'
         ELSE '' END AS note
  FROM pg_constraint c
  JOIN pg_class cl ON cl.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = cl.relnamespace
  JOIN pg_class rcl ON rcl.oid = c.confrelid
  JOIN pg_namespace rn ON rn.oid = rcl.relnamespace
  LEFT JOIN pg_stat_user_tables st ON st.relid = c.conrelid
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
  ORDER BY coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) DESC,
           pg_relation_size(c.conrelid) DESC;
  " -x

  local HIDDEN_FK
  HIDDEN_FK="$(psql_get "
  SELECT count(*)
  FROM pg_constraint c
  LEFT JOIN pg_stat_user_tables st ON st.relid = c.conrelid
  WHERE c.contype = 'f'
    AND pg_relation_size(c.conrelid) <= 10 * 1024 * 1024
    AND coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) <= 100
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
    );" "0")"
  if [[ "$HIDDEN_FK" =~ ^[0-9]+$ && "$HIDDEN_FK" -gt 0 ]]; then
    echo "   (+${HIDDEN_FK} unindexed FK(s) on small/cold child tables hidden — below 10MB and 100 writes)"
  fi

  run_section "redundant indexes (prefix-covered; verify both definitions before DROP)" "
  SELECT
    n.nspname || '.' || t.relname AS table,
    ci1.relname AS redundant_index,
    pg_size_pretty(pg_relation_size(i1.indexrelid)) AS redundant_size,
    ci2.relname AS covering_index,
    pg_get_indexdef(i1.indexrelid) AS redundant_def,
    pg_get_indexdef(i2.indexrelid) AS covering_def
  FROM pg_index i1
  JOIN pg_index i2 ON i1.indrelid = i2.indrelid AND i1.indexrelid <> i2.indexrelid
  JOIN pg_class ci1 ON ci1.oid = i1.indexrelid
  JOIN pg_class ci2 ON ci2.oid = i2.indexrelid
  JOIN pg_class t ON t.oid = i1.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND i1.indpred IS NULL AND i2.indpred IS NULL
    AND i1.indexprs IS NULL AND i2.indexprs IS NULL
    AND i1.indisvalid AND i2.indisvalid
    AND NOT i1.indisunique
    AND NOT i1.indisreplident
    AND NOT i1.indisclustered
    AND NOT EXISTS (SELECT 1 FROM pg_constraint cc WHERE cc.conindid = i1.indexrelid)
    AND i1.indnatts = i1.indnkeyatts
    AND i2.indnkeyatts >= i1.indnkeyatts
    AND (i2.indkey::smallint[])[0:i1.indnkeyatts - 1]
      = (i1.indkey::smallint[])[0:i1.indnkeyatts - 1]
    AND (i2.indclass::oid[])[0:i1.indnkeyatts - 1]
      = (i1.indclass::oid[])[0:i1.indnkeyatts - 1]
    AND (i2.indcollation::oid[])[0:i1.indnkeyatts - 1]
      = (i1.indcollation::oid[])[0:i1.indnkeyatts - 1]
    AND (i2.indoption::smallint[])[0:i1.indnkeyatts - 1]
      = (i1.indoption::smallint[])[0:i1.indnkeyatts - 1]
    AND (i1.indnkeyatts < i2.indnkeyatts
         OR i2.indnatts > i2.indnkeyatts
         OR i1.indexrelid > i2.indexrelid)
  ORDER BY pg_relation_size(i1.indexrelid) DESC;
  " -x

  run_section "zero-scan indexes (evidence: lifetime — see stats-window caveat above)" "
  SELECT
    s.schemaname || '.' || s.relname AS table,
    s.indexrelname AS index,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
    pg_get_indexdef(i.indexrelid) AS definition,
    coalesce(
      (SELECT sd.stats_reset FROM pg_stat_database sd WHERE sd.datname = current_database()),
      (SELECT min(io.stats_reset) FROM pg_stat_io io))::date::text AS stats_since
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON i.indexrelid = s.indexrelid
  WHERE s.idx_scan = 0
    AND i.indisvalid
    AND NOT i.indisprimary
    AND NOT i.indisunique
    AND NOT i.indisexclusion
    AND NOT i.indisreplident
    AND NOT i.indisclustered
    AND NOT EXISTS (SELECT 1 FROM pg_constraint cc WHERE cc.conindid = i.indexrelid)
  ORDER BY pg_relation_size(s.indexrelid) DESC
  LIMIT 30;
  " -x

  if [[ "$HAS_PGSS" != "t" ]]; then
    echo
    echo "   ⚠  pg_stat_statements not usable — plan-driven candidates skipped."
    return 0
  fi

  echo
  echo "── plan-driven index candidates ──"
  echo "   (EXPLAIN GENERIC_PLAN on top pg_stat_statements queries)"
  echo "   Seq Scan + Filter            → index candidate on filter columns"
  echo "   Index/Bitmap scan + Filter   → rows fetched by index then discarded → extend index or partial predicate"
  echo "   large Sort                   → index providing order, or work_mem"
  echo "   (generic plans use default selectivity for parameters — est_rows are crude;"
  echo "    unplannable statements are skipped silently — see coverage line below)"

  set +e
  psql_run_tolerant <<IDX_SQL
SET statement_timeout = '120s';
SET lock_timeout = '2s';

CREATE FUNCTION pg_temp.explain_generic(q text) RETURNS jsonb
LANGUAGE plpgsql AS \$fn\$
DECLARE r json;
BEGIN
  EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || q INTO r;
  RETURN r::jsonb;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
\$fn\$;

CREATE TEMP TABLE ix_top AS
SELECT s.queryid, s.calls, s.total_exec_time, s.mean_exec_time, s.query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
WHERE s.calls > 5
  AND s.query ~* '^[[:space:]]*(select|with|update|delete|insert)'
  AND ${PGSS_FILTER}
ORDER BY s.total_exec_time DESC
LIMIT 15;

CREATE TEMP TABLE ix_plans AS
SELECT t.queryid, t.calls, t.total_exec_time, t.mean_exec_time, t.query,
       pg_temp.explain_generic(t.query) AS plan
FROM ix_top t;

\echo
\echo '── generic-plan coverage ──'
SELECT
  count(*) AS top_stmts_checked,
  count(*) FILTER (WHERE plan IS NULL) AS skipped_unplannable
FROM ix_plans;

CREATE TEMP TABLE ix_nodes AS
WITH RECURSIVE nodes (queryid, calls, mean_exec_time, query, node) AS (
  SELECT p.queryid, p.calls, p.mean_exec_time, p.query, p.plan -> 0 -> 'Plan'
  FROM ix_plans p
  WHERE p.plan IS NOT NULL
  UNION ALL
  SELECT n.queryid, n.calls, n.mean_exec_time, n.query, child.value
  FROM nodes n
  CROSS JOIN LATERAL jsonb_array_elements(n.node -> 'Plans') AS child
  WHERE jsonb_typeof(n.node -> 'Plans') = 'array'
)
SELECT * FROM nodes;

\echo
\echo '── candidates ──'
\x on
SELECT
  queryid,
  calls,
  mean_exec_time::int AS mean_ms,
  node ->> 'Node Type' AS node_type,
  node ->> 'Relation Name' AS relation,
  node ->> 'Index Name' AS index_name,
  left(coalesce(node ->> 'Index Cond', node ->> 'Recheck Cond'), 120) AS index_cond,
  left(coalesce(node ->> 'Filter', (node -> 'Sort Key')::text), 160) AS predicate_or_sort_key,
  (node ->> 'Plan Rows')::bigint AS est_rows,
  (node ->> 'Total Cost')::numeric(14,1) AS total_cost,
  left(query, 200) AS query
FROM ix_nodes
WHERE (node ->> 'Node Type' = 'Seq Scan' AND node ? 'Filter')
   OR (node ->> 'Node Type' IN ('Index Scan', 'Index Only Scan', 'Bitmap Heap Scan')
       AND node ? 'Filter')
   OR (node ->> 'Node Type' IN ('Sort', 'Incremental Sort')
       AND (node ->> 'Plan Rows')::bigint > 10000)
ORDER BY (node ->> 'Total Cost')::numeric DESC NULLS LAST
LIMIT 30;
\x off
IDX_SQL
  if [[ $? -ne 0 ]]; then
    RUN_FAILED=1
    echo "   ⚠  Plan-driven candidate analysis could not run."
  fi
  set -e
}
