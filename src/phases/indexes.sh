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

  run_section "all user indexes (complete inventory; evidence: static — use this to reconcile against your ORM schema / spot out-of-band indexes and tables)" "
  SELECT
    s.schemaname || '.' || s.relname AS table,
    s.indexrelname AS index,
    pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
    s.idx_scan,
    i.indisvalid AS valid,
    pg_get_indexdef(i.indexrelid) AS definition
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON i.indexrelid = s.indexrelid
  WHERE s.schemaname NOT LIKE 'pg\_temp%'
  ORDER BY 1, pg_relation_size(s.indexrelid) DESC;
  " -x

  run_section "unindexed FK columns (child > 10MB or > 100 writes; soft-delete parents annotated)" "
  SELECT
    n.nspname || '.' || cl.relname AS child_table,
    c.conname AS fk_constraint,
    (SELECT string_agg(a.attname, ', ' ORDER BY x.ord)
       FROM unnest(c.conkey) WITH ORDINALITY AS x(attnum, ord)
       JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum) AS fk_columns,
    rn.nspname || '.' || rcl.relname AS referenced_table,
    CASE c.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL'
         WHEN 'd' THEN 'SET DEFAULT' WHEN 'r' THEN 'RESTRICT'
         ELSE 'NO ACTION' END AS on_delete,
    coalesce(pst.n_tup_del, 0) AS parent_deletes,
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
  LEFT JOIN pg_stat_user_tables pst ON pst.relid = c.confrelid
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

  run_section "redundant indexes (prefix-covered or equal to a unique index; verify both definitions before DROP; scans of the redundant index shift to the covering one after DROP)" "
  SELECT
    n.nspname || '.' || t.relname AS table,
    ci1.relname AS redundant_index,
    pg_size_pretty(pg_relation_size(i1.indexrelid)) AS redundant_size,
    coalesce(ui1.idx_scan, 0) AS redundant_scans,
    ci2.relname AS covering_index,
    pg_size_pretty(pg_relation_size(i2.indexrelid)) AS covering_size,
    pg_get_indexdef(i1.indexrelid) AS redundant_def,
    pg_get_indexdef(i2.indexrelid) AS covering_def
  FROM pg_index i1
  JOIN pg_index i2 ON i1.indrelid = i2.indrelid AND i1.indexrelid <> i2.indexrelid
  JOIN pg_class ci1 ON ci1.oid = i1.indexrelid
  JOIN pg_class ci2 ON ci2.oid = i2.indexrelid
  JOIN pg_class t ON t.oid = i1.indrelid
  JOIN pg_namespace n ON n.oid = t.relnamespace
  LEFT JOIN pg_stat_user_indexes ui1 ON ui1.indexrelid = i1.indexrelid
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
         OR i2.indisunique
         OR EXISTS (SELECT 1 FROM pg_constraint cc2 WHERE cc2.conindid = i2.indexrelid)
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
  echo "   (EXPLAIN GENERIC_PLAN on top pg_stat_statements queries; statements the"
  echo "    generic planner rejects are retried with typed literals rewritten to"
  echo "    casts — interval \$1 → \$1::interval — and then with parameters replaced"
  echo "    by NULL; null-params plans have meaningless est_rows)"
  echo "   Seq Scan + Filter            → index candidate on filter columns"
  echo "   Index/Bitmap scan + Filter   → rows fetched by index then discarded → extend index or partial predicate"
  echo "   large Sort                   → index providing order, or work_mem"
  echo "   (generic plans use default selectivity for parameters — est_rows are crude;"
  echo "    statements with no plan at all are listed with the planner's error)"

  set +e
  psql_run_tolerant <<IDX_SQL
SET statement_timeout = '180s';
SET lock_timeout = '2s';

CREATE FUNCTION pg_temp.rewrite_typed_literals(q text) RETURNS text
LANGUAGE sql AS \$fn\$
  SELECT regexp_replace(q,
    '\m(interval|date|timestamp(?:[[:space:]]+with(?:out)?[[:space:]]+time[[:space:]]+zone)?|time(?:[[:space:]]+with(?:out)?[[:space:]]+time[[:space:]]+zone)?)[[:space:]]+([\$][0-9]+)',
    '\2::\1', 'gi')
\$fn\$;

CREATE FUNCTION pg_temp.explain_try(q text, OUT plan jsonb, OUT planmode text, OUT err text)
LANGUAGE plpgsql AS \$fn\$
DECLARE r json;
BEGIN
  BEGIN
    EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || q INTO r;
    plan := r::jsonb;
    planmode := 'generic';
    RETURN;
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
  END;
  BEGIN
    EXECUTE 'EXPLAIN (GENERIC_PLAN, FORMAT JSON) ' || pg_temp.rewrite_typed_literals(q) INTO r;
    plan := r::jsonb;
    planmode := 'generic-rewritten';
    RETURN;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  BEGIN
    EXECUTE 'EXPLAIN (FORMAT JSON) '
      || regexp_replace(q, '[\$][0-9]+', 'NULL', 'g') INTO r;
    plan := r::jsonb;
    planmode := 'null-params';
    RETURN;
  EXCEPTION WHEN OTHERS THEN
    err := err || ' || null-params: ' || SQLERRM;
    planmode := 'failed';
  END;
END
\$fn\$;

CREATE TEMP TABLE ix_base AS
SELECT s.queryid, s.calls, s.total_exec_time, s.mean_exec_time, s.temp_blks_written, s.query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
WHERE s.calls > 5
  AND s.query ~* '^[[:space:]]*(select|with|update|delete|insert)'
  AND ${PGSS_FILTER};

CREATE TEMP TABLE ix_top AS
SELECT DISTINCT ON (queryid)
  queryid, calls, total_exec_time, mean_exec_time, query
FROM (
  (SELECT * FROM ix_base ORDER BY total_exec_time DESC LIMIT 15)
  UNION ALL
  (SELECT * FROM ix_base WHERE mean_exec_time > 50 ORDER BY mean_exec_time DESC LIMIT 15)
  UNION ALL
  (SELECT * FROM ix_base WHERE temp_blks_written > 1000 ORDER BY temp_blks_written DESC LIMIT 10)
) u
ORDER BY queryid;

CREATE TEMP TABLE ix_plans AS
SELECT t.queryid, t.calls, t.total_exec_time, t.mean_exec_time, t.query,
       e.plan, e.planmode, e.err
FROM ix_top t
CROSS JOIN LATERAL pg_temp.explain_try(t.query) e;

\echo
\echo '── plan coverage ──'
SELECT
  count(*) AS stmts_checked,
  count(*) FILTER (WHERE planmode = 'generic') AS generic_plans,
  count(*) FILTER (WHERE planmode = 'generic-rewritten') AS rewritten_generic_plans,
  count(*) FILTER (WHERE planmode = 'null-params') AS null_param_fallbacks,
  count(*) FILTER (WHERE plan IS NULL) AS unplannable
FROM ix_plans;

\echo
\echo '── statements planned via fallback or excluded from candidates ──'
SELECT
  queryid,
  planmode,
  left(err, 200) AS planner_error,
  CASE WHEN plan IS NULL AND query ~ '(<->|<=>|<#>|<\+>)'
       THEN 'vector distance operator in text — review manually'
       WHEN plan IS NULL AND query ~ '(@>|&&|<@)'
       THEN 'container operator in text — review manually'
       ELSE '' END AS note,
  left(query, 400) AS query
FROM ix_plans
WHERE planmode NOT IN ('generic', 'generic-rewritten')
ORDER BY total_exec_time DESC;

CREATE TEMP TABLE ix_nodes AS
WITH RECURSIVE nodes (queryid, calls, mean_exec_time, planmode, query, node) AS (
  SELECT p.queryid, p.calls, p.mean_exec_time, p.planmode, p.query, p.plan -> 0 -> 'Plan'
  FROM ix_plans p
  WHERE p.plan IS NOT NULL
  UNION ALL
  SELECT n.queryid, n.calls, n.mean_exec_time, n.planmode, n.query, child.value
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
  planmode,
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