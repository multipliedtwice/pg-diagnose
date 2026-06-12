#!/usr/bin/env bash

phase_history() {
  if [[ "$HAS_PGSS" != "t" ]]; then
    echo
    echo "⚠  pg_stat_statements not usable — historical query analysis unavailable."
    echo "   On DigitalOcean Managed PostgreSQL the library is preloaded; run"
    echo "   CREATE EXTENSION pg_stat_statements; in this database to enable it."
    return 0
  fi

  local DEALLOC
  DEALLOC="$(psql_run -At -c "SELECT dealloc FROM pg_stat_statements_info;" 2>/dev/null || echo "unknown")"
  if [[ "$DEALLOC" != "0" && "$DEALLOC" != "unknown" ]]; then
    echo
    echo "   ⚠  pg_stat_statements has deallocated ${DEALLOC} times — historical data may be incomplete."
    echo "      Consider increasing pg_stat_statements.max."
  fi

  echo
  echo "   (query text below is truncated to 200 chars — full normalized text:"
  echo "    $0 --explain-queryid=<queryid>)"

  run_section "live active queries vs. historical stats (evidence: lifetime)" "
  SELECT
    a.pid,
    a.query_id,
    clock_timestamp() - a.query_start AS live_duration,
    s.calls,
    s.mean_exec_time::int   AS hist_mean_ms,
    s.total_exec_time::int  AS hist_total_ms,
    s.shared_blks_read      AS hist_blks_read,
    left(a.query, 200)      AS query
  FROM pg_stat_activity a
  LEFT JOIN pg_stat_statements s
    ON s.dbid = a.datid
   AND s.userid = a.usesysid
   AND s.queryid = a.query_id
   AND s.toplevel
  WHERE a.state = 'active'
    AND coalesce(a.wait_event_type, '') <> 'Activity'
    AND a.pid <> pg_backend_pid()
  ORDER BY a.query_start;
  " -x

  run_section "top queries by total time — biggest overall CPU consumers (evidence: lifetime)" "
  SELECT
    s.queryid,
    s.calls,
    s.total_exec_time::int  AS total_ms,
    s.mean_exec_time::int   AS mean_ms,
    s.max_exec_time::int    AS max_ms,
    s.rows,
    s.shared_blks_read,
    left(s.query, 200)      AS query
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  WHERE ${PGSS_FILTER}
  ORDER BY s.total_exec_time DESC
  LIMIT 15;
  " -x

  run_section "top queries by mean time — slowest per call (>5 calls, mean >50ms, evidence: lifetime)" "
  SELECT
    s.queryid,
    s.calls,
    s.mean_exec_time::int  AS mean_ms,
    s.max_exec_time::int   AS max_ms,
    s.total_exec_time::int AS total_ms,
    left(s.query, 200)     AS query
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  WHERE s.calls > 5
    AND s.mean_exec_time > 50
    AND ${PGSS_FILTER}
  ORDER BY s.mean_exec_time DESC
  LIMIT 15;
  " -x

  run_section "unstable queries — high run-to-run variance means plan flips, parameter skew, or contention (evidence: lifetime)" "
  SELECT
    s.queryid,
    s.calls,
    s.mean_exec_time::numeric(12,2)   AS mean_ms,
    s.stddev_exec_time::numeric(12,2) AS stddev_ms,
    s.min_exec_time::numeric(12,2)    AS min_ms,
    s.max_exec_time::numeric(12,2)    AS max_ms,
    left(s.query, 200)                AS query
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  WHERE s.calls > 5
    AND s.stddev_exec_time > 100
    AND ${PGSS_FILTER}
  ORDER BY s.stddev_exec_time DESC
  LIMIT 15;
  " -x

  echo
  echo "── parallel worker usage per query — launched < to_launch means worker starvation ──"
  set +e
  psql_run_tolerant -x -c "
  SELECT
    s.queryid,
    s.calls,
    s.parallel_workers_to_launch,
    s.parallel_workers_launched,
    round(100.0 * s.parallel_workers_launched
          / NULLIF(s.parallel_workers_to_launch, 0), 1) AS launched_pct,
    s.mean_exec_time::int AS mean_ms,
    left(s.query, 200) AS query
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  WHERE s.parallel_workers_to_launch > 0
    AND ${PGSS_FILTER}
  ORDER BY s.parallel_workers_to_launch DESC
  LIMIT 15;
  " || echo "   (parallel-worker columns unavailable on this pg_stat_statements version)"
  set -e

  run_section "top queries by WAL generated — heaviest writers (>1MB lifetime, evidence: lifetime)" "
  SELECT
    s.queryid,
    s.calls,
    pg_size_pretty(s.wal_bytes::bigint) AS wal_size,
    s.wal_records,
    s.wal_fpi,
    s.wal_buffers_full,
    s.mean_exec_time::int AS mean_ms,
    left(s.query, 200) AS query
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  WHERE s.wal_bytes > 1024 * 1024
    AND ${PGSS_FILTER}
  ORDER BY s.wal_bytes DESC
  LIMIT 15;
  " -x

  if [[ "$TRACK_PLANNING" == "on" ]]; then
    run_section "top queries by planning time — high plan time means complex parsing or plan cache misses (evidence: lifetime)" "
    SELECT
      s.queryid,
      s.calls,
      s.total_plan_time::int AS total_plan_ms,
      s.mean_plan_time::numeric(12,2) AS mean_plan_ms,
      s.total_exec_time::int AS total_exec_ms,
      s.mean_exec_time::numeric(12,2) AS mean_exec_ms,
      left(s.query, 200) AS query
    FROM pg_stat_statements s
    JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
    WHERE s.total_plan_time > 0
      AND ${PGSS_FILTER}
    ORDER BY s.total_plan_time DESC
    LIMIT 15;
    " -x
  else
    echo
    echo "── top queries by planning time ──"
    echo "   (skipped: pg_stat_statements.track_planning=${TRACK_PLANNING} — planning counters are zero)"
  fi

  run_section "top queries by temp usage — sort/hash spilling to disk (>1000 blocks, evidence: lifetime)" "
  SELECT
    s.queryid,
    s.calls,
    s.temp_blks_read,
    s.temp_blks_written,
    s.total_exec_time::int AS total_ms,
    s.mean_exec_time::int AS mean_ms,
    left(s.query, 200) AS query
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  WHERE s.temp_blks_read + s.temp_blks_written > 1000
    AND ${PGSS_FILTER}
  ORDER BY s.temp_blks_written + s.temp_blks_read DESC
  LIMIT 15;
  " -x
}