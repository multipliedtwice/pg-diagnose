#!/usr/bin/env bash

deep_queryid_helper() {
  local DEEP_OUT DEEP_RC DEEP_ERRS
  local PLAN_SOURCE_SQL PLAN_TEXT_SECTION PLAN_ORIGIN
  local REAL_PLAN="" TMP_EXPLAIN EXPLAIN_RC
  local -a EXTRA_ARGS=()

  if ! [[ "$DEEP_QUERYID" =~ ^-?[0-9]+$ ]]; then
    echo "--deep-queryid must be a bigint queryid (got: $DEEP_QUERYID)" >&2
    exit 1
  fi
  if [[ "$HAS_PGSS" != "t" ]]; then
    echo "pg_stat_statements not usable — deep mode unavailable." >&2
    exit 1
  fi

  PLAN_ORIGIN="generic"
  if [[ -n "$EXPLAIN_SQL_FILE" ]]; then
    if [[ ! -s "$EXPLAIN_SQL_FILE" ]]; then
      echo "--explain-sql file is missing or empty: ${EXPLAIN_SQL_FILE}" >&2
      exit 1
    fi
    TMP_EXPLAIN="$(mktemp "${TMPDIR:-/tmp}/pg-diagnose-explain.XXXXXX")"
    printf 'EXPLAIN (VERBOSE, FORMAT JSON) ' > "$TMP_EXPLAIN"
    cat "$EXPLAIN_SQL_FILE" >> "$TMP_EXPLAIN"
    set +e
    REAL_PLAN="$(psql_run_tolerant -At -f "$TMP_EXPLAIN" 2>/dev/null)"
    EXPLAIN_RC=$?
    set -e
    rm -f "$TMP_EXPLAIN"
    if [[ $EXPLAIN_RC -ne 0 || -z "$REAL_PLAN" || "$REAL_PLAN" != \[* ]]; then
      echo "   ⚠  could not obtain a real plan from --explain-sql (statement rejected by EXPLAIN," >&2
      echo "      multiple statements in file, or syntax error) — falling back to the generic plan." >&2
      REAL_PLAN=""
    else
      PLAN_ORIGIN="real"
    fi
  fi

  if [[ "$PLAN_ORIGIN" == "real" ]]; then
    PLAN_SOURCE_SQL="CREATE TEMP TABLE deep_plan AS SELECT :'real_plan'::jsonb AS plan;"
    PLAN_TEXT_SECTION="\echo
\echo '── plan source ──'
\echo '   real-selectivity plan from --explain-sql (EXPLAIN only — the statement was NOT executed).'
\echo '   parameter selectivity reflects the literals in the supplied statement, not planner defaults.'"
    EXTRA_ARGS=(-v "real_plan=${REAL_PLAN}")
  else
    PLAN_SOURCE_SQL="CREATE TEMP TABLE deep_plan AS SELECT pg_temp.explain_generic(query) AS plan FROM deep_q;"
    PLAN_TEXT_SECTION="\echo
\echo '── generic plan (text) ──'
SELECT pg_temp.explain_generic_text(query) AS generic_plan FROM deep_q;"
  fi

  echo
  echo "╔═══════════════════════════════════════════════════════╗"
  echo "║   Deep diagnosis: queryid=${DEEP_QUERYID}"
  echo "║   evidence for index/query design — no auto-DDL       ║"
  echo "╚═══════════════════════════════════════════════════════╝"
  if [[ "$PLAN_ORIGIN" == "real" ]]; then
    echo "   plan source: --explain-sql (real selectivity; statement NOT executed)"
    echo "   pg_stat_statements metrics below are workload context for the named queryid;"
    echo "   you are asserting the supplied statement corresponds to it."
  else
    echo "   (plan-derived sections use the generic plan: parameter selectivity is"
    echo "    estimated with defaults, so est. rows are crude. For a real-selectivity"
    echo "    plan with no manual EXPLAIN, capture one slow-query statement with literals"
    echo "    (log_min_duration_statement / auto_explain) and pass it via:"
    echo "      $0 --deep-queryid=${DEEP_QUERYID} --explain-sql=stmt.sql)"
  fi

  set +e
  DEEP_OUT="$(psql_run_tolerant "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" 2>&1 <<DEEP_SQL
SET statement_timeout = '120s';
SET lock_timeout = '2s';

CREATE FUNCTION pg_temp.explain_generic(q text) RETURNS jsonb
LANGUAGE plpgsql AS \$fn\$
DECLARE r json;
BEGIN
  EXECUTE 'EXPLAIN (GENERIC_PLAN, VERBOSE, FORMAT JSON) ' || q INTO r;
  RETURN r::jsonb;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
\$fn\$;

CREATE FUNCTION pg_temp.explain_generic_text(q text) RETURNS SETOF text
LANGUAGE plpgsql AS \$fn\$
DECLARE l text;
BEGIN
  FOR l IN EXECUTE 'EXPLAIN (GENERIC_PLAN, VERBOSE) ' || q LOOP
    RETURN NEXT l;
  END LOOP;
EXCEPTION WHEN OTHERS THEN
  RETURN NEXT 'generic plan unavailable: ' || SQLERRM;
END
\$fn\$;

CREATE TEMP TABLE deep_q AS
SELECT s.queryid, s.calls, s.mean_exec_time, s.max_exec_time, s.total_exec_time,
       s.shared_blks_read, s.temp_blks_written, s.wal_bytes, s.query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
WHERE s.queryid = ${DEEP_QUERYID}
ORDER BY s.calls DESC
LIMIT 1;

SELECT CASE WHEN count(*) = 0
  THEN '⚠ queryid not found in pg_stat_statements for the current database (evicted or wrong DB?)'
  ELSE 'queryid found'
END AS lookup
FROM deep_q;

\echo
\echo '── statement summary (evidence: lifetime) ──'
\x on
SELECT
  queryid,
  calls,
  mean_exec_time::numeric(12,2) AS mean_ms,
  max_exec_time::numeric(12,2) AS max_ms,
  total_exec_time::int AS total_ms,
  shared_blks_read,
  temp_blks_written,
  pg_size_pretty(wal_bytes::bigint) AS wal_size,
  query
FROM deep_q;
\x off

${PLAN_SOURCE_SQL}

CREATE TEMP TABLE deep_nodes AS
WITH RECURSIVE nodes(node) AS (
  SELECT plan -> 0 -> 'Plan' FROM deep_plan WHERE plan IS NOT NULL
  UNION ALL
  SELECT child.value
  FROM nodes n
  CROSS JOIN LATERAL jsonb_array_elements(n.node -> 'Plans') AS child
  WHERE jsonb_typeof(n.node -> 'Plans') = 'array'
)
SELECT node FROM nodes;

CREATE TEMP TABLE deep_rels AS
SELECT DISTINCT
  coalesce(node ->> 'Schema', 'public') AS schemaname,
  node ->> 'Relation Name' AS relname
FROM deep_nodes
WHERE node ? 'Relation Name';

\echo
\echo '── referenced tables (from plan) ──'
SELECT
  r.schemaname || '.' || c.relname AS table,
  CASE WHEN c.reltuples < 0 THEN '-1 (never analyzed)'
       ELSE c.reltuples::bigint::text END AS reltuples,
  c.relpages,
  pg_size_pretty(pg_relation_size(c.oid)) AS heap_size,
  pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
  s.n_live_tup,
  s.n_dead_tup,
  s.n_mod_since_analyze,
  greatest(s.last_analyze, s.last_autoanalyze) AS last_analyzed
FROM deep_rels r
JOIN pg_namespace n ON n.nspname = r.schemaname
JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = r.relname
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
ORDER BY pg_total_relation_size(c.oid) DESC;

\echo
\echo '── existing indexes on referenced tables ──'
\x on
SELECT
  r.schemaname || '.' || c.relname AS table,
  ci.relname AS index,
  pg_size_pretty(pg_relation_size(i.indexrelid)) AS size,
  ui.idx_scan,
  i.indisvalid AS valid,
  pg_get_indexdef(i.indexrelid) AS definition
FROM deep_rels r
JOIN pg_namespace n ON n.nspname = r.schemaname
JOIN pg_class c ON c.relnamespace = n.oid AND c.relname = r.relname
JOIN pg_index i ON i.indrelid = c.oid
JOIN pg_class ci ON ci.oid = i.indexrelid
LEFT JOIN pg_stat_user_indexes ui ON ui.indexrelid = i.indexrelid
ORDER BY 1, pg_relation_size(i.indexrelid) DESC;
\x off

CREATE TEMP TABLE deep_preds AS
SELECT DISTINCT
  node ->> 'Relation Name' AS relname,
  k.clause_type,
  CASE WHEN jsonb_typeof(node -> k.clause_type) = 'array'
       THEN (node -> k.clause_type)::text
       ELSE node ->> k.clause_type
  END AS clause
FROM deep_nodes
CROSS JOIN LATERAL (VALUES
  ('Filter'), ('Index Cond'), ('Recheck Cond'), ('Join Filter'), ('Sort Key')
) AS k(clause_type)
WHERE node ? k.clause_type;

\echo
\echo '── plan predicates and sort keys ──'
SELECT relname, clause_type, left(clause, 300) AS clause
FROM deep_preds
ORDER BY relname NULLS LAST, clause_type;

\echo
\echo '── column statistics for predicate/sort columns ──'
\echo '   (n_distinct < 0 means fraction of rows; correlation near ±1 favors range/order'
\echo '    scans on that column; high null_frac favors partial indexes with IS NOT NULL)'
WITH clauses AS (
  SELECT coalesce(string_agg(clause, ' '), '') AS alltext FROM deep_preds
)
SELECT
  st.schemaname || '.' || st.tablename AS table,
  st.attname,
  st.null_frac,
  st.n_distinct,
  st.correlation,
  left(st.most_common_vals::text, 80) AS most_common_vals,
  left(st.most_common_freqs::text, 60) AS most_common_freqs
FROM pg_stats st
JOIN deep_rels r ON r.relname = st.tablename AND r.schemaname = st.schemaname
CROSS JOIN clauses cl
WHERE CASE WHEN st.attname ~ '^[A-Za-z_][A-Za-z0-9_]*\$'
           THEN cl.alltext ~ ('\m' || st.attname || '\M')
           ELSE strpos(cl.alltext, st.attname) > 0 END
ORDER BY 1, 2;

${PLAN_TEXT_SECTION}
DEEP_SQL
)"
  DEEP_RC=$?
  set -e

  printf '%s\n' "$DEEP_OUT"

  DEEP_ERRS="$(count_sql_errors "$DEEP_OUT")"
  if [[ "${DEEP_ERRS:-0}" -gt 0 ]]; then
    RUN_FAILED=1
    echo
    echo "   ⚠  deep mode hit ${DEEP_ERRS} SQL error(s) — the evidence above is incomplete."
  fi
  if [[ $DEEP_RC -ne 0 ]]; then
    RUN_FAILED=1
    echo "   ⚠  Deep mode could not run (connection failure or fatal session error)."
  fi

  echo
  if [[ "$PLAN_ORIGIN" == "real" ]]; then
    echo "  The plan above used real selectivity from the supplied statement and was NOT executed."
    echo "  To measure actual timing, run EXPLAIN (ANALYZE, BUFFERS, WAL, VERBOSE) yourself on a"
    echo "  read-only copy of the statement; for writes, wrap in BEGIN; ... ROLLBACK;."
  else
    echo "  Real parameter values are not stored in pg_stat_statements, so the plan above is"
    echo "  generic. To get a real-selectivity plan without leaving this tool, capture one"
    echo "  slow-query statement (literals inline) and re-run with --explain-sql=<file>."
    echo "  For measured timing, EXPLAIN (ANALYZE, BUFFERS, WAL, VERBOSE) executes the statement —"
    echo "  wrap writes in BEGIN; ... ROLLBACK;."
  fi
}