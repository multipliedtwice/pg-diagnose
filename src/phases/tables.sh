#!/usr/bin/env bash

phase_tables() {
  run_section "table health: dead tuples, write pressure, vacuum/analyze lag (evidence: lifetime)" "
  SELECT
    schemaname || '.' || relname AS table,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    n_tup_hot_upd,
    n_mod_since_analyze,
    n_ins_since_vacuum,
    vacuum_count,
    autovacuum_count,
    autoanalyze_count,
    last_autovacuum,
    last_autoanalyze,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size
  FROM pg_stat_user_tables
  WHERE schemaname NOT LIKE 'pg\_temp%'
  ORDER BY n_dead_tup DESC
  LIMIT 30;
  "

  run_section "top tables by maintenance time (PG18, evidence: lifetime; ranked by vacuum+analyze combined)" "
  SELECT
    schemaname || '.' || relname AS table,
    (total_vacuum_time + total_autovacuum_time)::bigint AS vacuum_ms,
    (total_analyze_time + total_autoanalyze_time)::bigint AS analyze_ms,
    vacuum_count + autovacuum_count AS vacuums,
    analyze_count + autoanalyze_count AS analyzes,
    n_dead_tup,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
    CASE WHEN (total_analyze_time + total_autoanalyze_time)
            / NULLIF(analyze_count + autoanalyze_count, 0) > 60000
         THEN '⚠ expensive ANALYZE (>60s avg) — see ANALYZE cost attribution below'
         ELSE '' END AS note
  FROM pg_stat_user_tables
  WHERE schemaname NOT LIKE 'pg\_temp%'
    AND total_vacuum_time + total_autovacuum_time
      + total_analyze_time + total_autoanalyze_time > 0
  ORDER BY total_vacuum_time + total_autovacuum_time
         + total_analyze_time + total_autoanalyze_time DESC
  LIMIT 15;
  "

  run_section "ANALYZE cost attribution — columns of tables with avg ANALYZE > 60s (sampling detoasts every wide column; SET STATISTICS 0 skips a column entirely)" "
  SELECT
    x.table,
    a.attname AS column,
    format_type(a.atttypid, a.atttypmod) AS type,
    coalesce(a.attstattarget::text, 'default') AS stats_target,
    st.avg_width,
    st.n_distinct,
    CASE WHEN ty.typname IN ('vector', 'halfvec', 'sparsevec')
         THEN 'planner gains nothing from stats on vector types — SET STATISTICS 0 candidate'
         WHEN coalesce(st.avg_width, 0) > 1000
         THEN 'wide column — detoasted for every sampled row; lower target if never filtered on'
         ELSE '' END AS note
  FROM (
    SELECT s.relid, s.schemaname, s.relname,
           s.schemaname || '.' || s.relname AS table
    FROM pg_stat_user_tables s
    WHERE (s.total_analyze_time + s.total_autoanalyze_time)
        / NULLIF(s.analyze_count + s.autoanalyze_count, 0) > 60000
  ) x
  JOIN pg_attribute a ON a.attrelid = x.relid AND a.attnum > 0 AND NOT a.attisdropped
  JOIN pg_type ty ON ty.oid = a.atttypid
  LEFT JOIN pg_stats st ON st.schemaname = x.schemaname
                       AND st.tablename = x.relname
                       AND st.attname = a.attname
  ORDER BY x.table, coalesce(st.avg_width, 0) DESC, a.attnum;
  "

  run_section "transaction ID age / freeze risk (high xid_age forces aggressive anti-wraparound autovacuum — a hidden CPU source)" "
  SELECT
    n.nspname || '.' || c.relname AS table,
    age(c.relfrozenxid) AS xid_age,
    CASE WHEN c.relminmxid <> '0'::xid THEN mxid_age(c.relminmxid) END AS mxid_age,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    s.n_live_tup,
    s.n_dead_tup,
    s.last_autovacuum
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
  WHERE c.relkind IN ('r', 'm')
    AND c.relfrozenxid <> '0'::xid
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
  ORDER BY age(c.relfrozenxid) DESC
  LIMIT 30;
  "

  run_section "database-level transaction ID age" "
  SELECT datname, age(datfrozenxid) AS database_xid_age
  FROM pg_database
  WHERE datname = current_database();
  "

  run_section "heavy seq scans (selectivity-aware; full_scan_pct near 100 = index candidate)" "
  SELECT
    schemaname || '.' || relname  AS table,
    seq_scan,
    seq_tup_read,
    (seq_tup_read / NULLIF(seq_scan, 0))::bigint AS avg_rows_per_scan,
    round(100.0 * (seq_tup_read / NULLIF(seq_scan, 0))
      / NULLIF(n_live_tup, 0), 1) AS full_scan_pct,
    idx_scan,
    round(100.0 * idx_scan
      / NULLIF(seq_scan + idx_scan, 0), 1) AS idx_scan_pct,
    n_live_tup,
    pg_size_pretty(pg_relation_size(relid)) AS size
  FROM pg_stat_user_tables
  WHERE seq_scan > 0 AND n_live_tup > 50000
  ORDER BY seq_tup_read DESC
  LIMIT 10;
  "
}