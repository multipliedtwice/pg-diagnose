#!/usr/bin/env bash

phase_window() {
  echo
  echo "╔═══════════════════════════════════════════════════════"
  echo "║   Diagnostic window: ${SAMPLE_SECONDS}s (evidence: sampled — strongest)"
  echo "║   before-snapshots → 1Hz wait sampler → counter deltas"
  echo "╚═══════════════════════════════════════════════════════"
  echo "   (sampler: temp procedure committing per tick — no long-held snapshot;"
  echo "    idle main-loop waits — wait_event_type=Activity — are excluded)"
  echo "   (backend_samples counts per-backend: parallel workers multiply wall time,"
  echo "    so percentages are shares of backend-samples, not wall-clock time)"
  echo "   (rates are divided by actual elapsed time, not the nominal window length)"
  echo "   (samples cover the whole cluster — all databases; pg_stat_statements"
  echo "    deltas below cover only the current database)"
  echo "   (pgss entries evicted AND recreated mid-window report lifetime totals as in-window)"
  echo "   (SQL errors in this phase are tolerated and printed inline)"
  echo
  echo "   collecting for ${SAMPLE_SECONDS}s — output appears when the window completes..."

  set +e
  psql_run_tolerant <<DIAG_SQL
SET statement_timeout = '$((SAMPLE_SECONDS + 60))s';
SET lock_timeout = '2s';
SET stats_fetch_consistency = 'none';

SELECT /* pg-diagnose */ '${HAS_PGSS}' = 't' AS has_pgss \gset

CREATE TEMP TABLE diag_t0 AS
SELECT clock_timestamp() AS t0;

CREATE TEMP TABLE diag_reset_before AS
SELECT
  (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()) AS db_stats_reset,
  (SELECT stats_reset FROM pg_stat_wal) AS wal_stats_reset;

CREATE TEMP TABLE diag_db_before AS
SELECT xact_commit, xact_rollback, blks_read, blks_hit,
       tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
       temp_files, temp_bytes,
       active_time,
       parallel_workers_to_launch, parallel_workers_launched
FROM pg_stat_database
WHERE datname = current_database();

CREATE TEMP TABLE diag_wal_before AS
SELECT wal_records, wal_fpi, wal_bytes, wal_buffers_full
FROM pg_stat_wal;

CREATE TEMP TABLE diag_ckpt_before AS
SELECT num_timed, num_requested, num_done, write_time, sync_time, buffers_written
FROM pg_stat_checkpointer;

CREATE TEMP TABLE diag_io_before AS
SELECT backend_type, object, context,
       reads, coalesce(read_bytes, 0) AS read_bytes,
       writes, coalesce(write_bytes, 0) AS write_bytes,
       extends, coalesce(extend_bytes, 0) AS extend_bytes,
       hits, evictions, fsyncs
FROM pg_stat_io;

CREATE TEMP TABLE diag_tables_before AS
SELECT relid, schemaname, relname,
       seq_scan, seq_tup_read, idx_scan,
       n_tup_ins, n_tup_upd, n_tup_del
FROM pg_stat_user_tables
WHERE schemaname NOT LIKE 'pg\_temp%';

\if :has_pgss
CREATE TEMP TABLE diag_pgss_before AS
SELECT s.userid, s.dbid, s.toplevel, s.queryid,
       s.calls, s.total_exec_time, s.rows,
       s.shared_blks_hit, s.shared_blks_read,
       s.temp_blks_read, s.temp_blks_written,
       s.wal_records, s.wal_fpi, s.wal_bytes, s.wal_buffers_full
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database();
\endif

CREATE TEMP TABLE diag_samples (
  pid int,
  leader_pid int,
  query_key text,
  query_id bigint,
  wait_type text,
  wait_event text,
  backend_type text,
  application_name text,
  query_age interval,
  query text
);

CREATE PROCEDURE pg_temp.diag_sampler(ticks int)
LANGUAGE plpgsql AS \$\$
BEGIN
  FOR i IN 1..ticks LOOP
    INSERT INTO diag_samples
    SELECT
      a.pid,
      a.leader_pid,
      CASE WHEN a.query_id IS NOT NULL THEN a.query_id::text
           WHEN a.query IS NULL OR a.query = '<insufficient privilege>' THEN 'pid:' || a.pid
           ELSE 'text:' || md5(a.query) END,
      a.query_id,
      coalesce(a.wait_event_type, 'CPU'),
      coalesce(a.wait_event, '-'),
      a.backend_type,
      a.application_name,
      clock_timestamp() - a.query_start,
      a.query
    FROM pg_stat_activity a
    WHERE a.pid <> pg_backend_pid()
      AND a.state = 'active'
      AND coalesce(a.wait_event_type, '') <> 'Activity';
    COMMIT;
    PERFORM pg_stat_clear_snapshot();
    PERFORM pg_sleep(1);
  END LOOP;
END
\$\$;

/* pg-diagnose */
CALL pg_temp.diag_sampler(${SAMPLE_SECONDS});

\echo
\echo '── stats reset check ──'
SELECT
  CASE
    WHEN b.db_stats_reset IS DISTINCT FROM d.stats_reset
      THEN '⚠ pg_stat_database was reset during window — db/table deltas below are invalid'
    WHEN b.wal_stats_reset IS DISTINCT FROM w.stats_reset
      THEN '⚠ pg_stat_wal was reset during window — WAL delta below is invalid'
    ELSE 'ok — stats reset unchanged during window'
  END AS reset_check
FROM diag_reset_before b
CROSS JOIN (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()) d
CROSS JOIN (SELECT stats_reset FROM pg_stat_wal) w;

\echo
\echo '── wait profile (share of backend-samples, idle main loops excluded) ──'
SELECT
  wait_type,
  wait_event,
  count(*) AS backend_samples,
  round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM diag_samples
GROUP BY wait_type, wait_event
ORDER BY backend_samples DESC;

\echo
\echo '── sampled queries by wait class ──'
\echo '   (backend_samples = 1-second backend observations in this wait class;'
\echo '    pids = distinct backends, leaders = distinct non-worker backends)'
\x on
SELECT
  count(*) AS backend_samples,
  count(DISTINCT pid) AS pids,
  count(DISTINCT pid) FILTER (WHERE leader_pid IS NULL) AS leaders,
  wait_type,
  wait_event,
  max(query_id) AS query_id,
  max(backend_type) AS backend_type,
  max(application_name) AS app,
  max(query_age) AS max_duration,
  left(max(query), 200) AS query
FROM diag_samples
GROUP BY query_key, wait_type, wait_event
ORDER BY backend_samples DESC
LIMIT 30;
\x off

\echo
\echo '── window rates (pg_stat_database delta, this database) ──'
SELECT
  CASE WHEN a.xact_commit >= b.xact_commit
       THEN round((a.xact_commit - b.xact_commit) / e.secs, 1) END AS commits_per_s,
  CASE WHEN a.xact_rollback >= b.xact_rollback
       THEN round((a.xact_rollback - b.xact_rollback) / e.secs, 1) END AS rollbacks_per_s,
  CASE WHEN a.tup_returned >= b.tup_returned
       THEN round((a.tup_returned - b.tup_returned) / e.secs) END AS tup_returned_per_s,
  CASE WHEN a.tup_fetched >= b.tup_fetched
       THEN round((a.tup_fetched - b.tup_fetched) / e.secs) END AS tup_fetched_per_s,
  CASE WHEN a.tup_inserted + a.tup_updated + a.tup_deleted
        >= b.tup_inserted + b.tup_updated + b.tup_deleted
       THEN round((a.tup_inserted + a.tup_updated + a.tup_deleted
                 - b.tup_inserted - b.tup_updated - b.tup_deleted) / e.secs) END AS tup_written_per_s,
  CASE WHEN a.temp_files >= b.temp_files
       THEN a.temp_files - b.temp_files END AS temp_files_delta,
  CASE WHEN a.temp_bytes >= b.temp_bytes
       THEN pg_size_pretty(((a.temp_bytes - b.temp_bytes) / e.secs)::bigint) || '/s' END AS temp_rate,
  CASE WHEN a.active_time >= b.active_time
       THEN round(((a.active_time - b.active_time) / 1000.0 / e.secs)::numeric, 2) END AS avg_active_backends,
  CASE WHEN a.parallel_workers_to_launch >= b.parallel_workers_to_launch
       THEN a.parallel_workers_to_launch - b.parallel_workers_to_launch END AS pw_to_launch_delta,
  CASE WHEN a.parallel_workers_launched >= b.parallel_workers_launched
       THEN a.parallel_workers_launched - b.parallel_workers_launched END AS pw_launched_delta,
  CASE WHEN a.blks_hit >= b.blks_hit AND a.blks_read >= b.blks_read
       THEN round(100.0 * (a.blks_hit - b.blks_hit)
            / NULLIF((a.blks_hit - b.blks_hit) + (a.blks_read - b.blks_read), 0), 2) END AS window_hit_pct
FROM pg_stat_database a
CROSS JOIN diag_db_before b
CROSS JOIN LATERAL (
  SELECT greatest(extract(epoch FROM clock_timestamp() - t0), 1)::numeric AS secs
  FROM diag_t0
) e
WHERE a.datname = current_database();

\echo
\echo '── WAL delta (cluster-wide) ──'
SELECT
  a.wal_records - b.wal_records AS wal_records_delta,
  a.wal_fpi - b.wal_fpi AS wal_fpi_delta,
  pg_size_pretty((a.wal_bytes - b.wal_bytes)::bigint) AS wal_delta,
  pg_size_pretty(((a.wal_bytes - b.wal_bytes) / e.secs)::bigint) || '/s' AS wal_rate,
  a.wal_buffers_full - b.wal_buffers_full AS wal_buffers_full_delta,
  CASE WHEN a.wal_buffers_full - b.wal_buffers_full
            > 0.5 * greatest(a.wal_records - b.wal_records, 1)
       THEN '⚠ wal_buffers_full ≈ wal_records — WAL buffers saturating; see pg_stat_io wal rows'
       ELSE '' END AS note
FROM pg_stat_wal a
CROSS JOIN diag_wal_before b
CROSS JOIN LATERAL (
  SELECT greatest(extract(epoch FROM clock_timestamp() - t0), 1)::numeric AS secs
  FROM diag_t0
) e;

\echo
\echo '── checkpointer delta (cluster-wide) ──'
SELECT
  a.num_timed - b.num_timed AS timed_delta,
  a.num_requested - b.num_requested AS requested_delta,
  a.num_done - b.num_done AS done_delta,
  round((a.write_time - b.write_time)::numeric, 1) AS write_ms_delta,
  round((a.sync_time - b.sync_time)::numeric, 1) AS sync_ms_delta,
  a.buffers_written - b.buffers_written AS buffers_written_delta
FROM pg_stat_checkpointer a, diag_ckpt_before b;

\echo
\echo '── I/O delta by backend type (cluster-wide) ──'
SELECT
  a.backend_type,
  a.object,
  a.context,
  a.reads - b.reads AS reads_delta,
  pg_size_pretty((coalesce(a.read_bytes, 0) - b.read_bytes)::bigint) AS read_delta,
  a.writes - b.writes AS writes_delta,
  pg_size_pretty((coalesce(a.write_bytes, 0) - b.write_bytes)::bigint) AS write_delta,
  a.extends - b.extends AS extends_delta,
  a.hits - b.hits AS hits_delta,
  a.evictions - b.evictions AS evictions_delta
FROM pg_stat_io a
JOIN diag_io_before b
  ON b.backend_type = a.backend_type
 AND b.object = a.object
 AND b.context = a.context
WHERE (a.reads - b.reads) + (a.writes - b.writes)
    + (a.extends - b.extends) + (a.evictions - b.evictions) > 0
ORDER BY (coalesce(a.read_bytes, 0) - b.read_bytes)
       + (coalesce(a.write_bytes, 0) - b.write_bytes) DESC
LIMIT 20;

\echo
\echo '── top tables by writes in window ──'
SELECT
  a.schemaname || '.' || a.relname AS table,
  a.n_tup_ins - b.n_tup_ins AS ins_delta,
  a.n_tup_upd - b.n_tup_upd AS upd_delta,
  a.n_tup_del - b.n_tup_del AS del_delta,
  (a.n_tup_ins + a.n_tup_upd + a.n_tup_del
   - b.n_tup_ins - b.n_tup_upd - b.n_tup_del) AS writes_delta
FROM pg_stat_user_tables a
JOIN diag_tables_before b ON b.relid = a.relid
WHERE a.n_tup_ins + a.n_tup_upd + a.n_tup_del
    > b.n_tup_ins + b.n_tup_upd + b.n_tup_del
ORDER BY writes_delta DESC
LIMIT 15;

\echo
\echo '── top tables by seq reads in window ──'
SELECT
  a.schemaname || '.' || a.relname AS table,
  a.seq_scan - b.seq_scan AS seq_scans_delta,
  a.seq_tup_read - b.seq_tup_read AS seq_tup_read_delta,
  a.idx_scan - b.idx_scan AS idx_scans_delta
FROM pg_stat_user_tables a
JOIN diag_tables_before b ON b.relid = a.relid
WHERE a.seq_tup_read > b.seq_tup_read
ORDER BY seq_tup_read_delta DESC
LIMIT 15;

\if :has_pgss
\echo
\echo '── top queries by exec time in window ──'
\x on
SELECT
  s.queryid,
  (b.queryid IS NULL) AS new_in_window,
  s.calls - coalesce(b.calls, 0) AS calls_delta,
  round((s.total_exec_time - coalesce(b.total_exec_time, 0))::numeric, 1) AS exec_ms_delta,
  s.rows - coalesce(b.rows, 0) AS rows_delta,
  s.shared_blks_read - coalesce(b.shared_blks_read, 0) AS blks_read_delta,
  s.temp_blks_written - coalesce(b.temp_blks_written, 0) AS temp_written_delta,
  pg_size_pretty((s.wal_bytes - coalesce(b.wal_bytes, 0))::bigint) AS wal_delta,
  left(s.query, 200) AS query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
LEFT JOIN diag_pgss_before b
  ON b.userid = s.userid
 AND b.dbid = s.dbid
 AND b.toplevel = s.toplevel
 AND b.queryid = s.queryid
WHERE ${PGSS_FILTER}
  AND (s.total_exec_time > coalesce(b.total_exec_time, 0)
       OR s.calls > coalesce(b.calls, 0))
ORDER BY s.total_exec_time - coalesce(b.total_exec_time, 0) DESC
LIMIT 20;
\x off

\echo
\echo '── top queries by WAL in window ──'
\x on
SELECT
  s.queryid,
  (b.queryid IS NULL) AS new_in_window,
  s.calls - coalesce(b.calls, 0) AS calls_delta,
  pg_size_pretty((s.wal_bytes - coalesce(b.wal_bytes, 0))::bigint) AS wal_delta,
  s.wal_records - coalesce(b.wal_records, 0) AS wal_records_delta,
  s.wal_fpi - coalesce(b.wal_fpi, 0) AS wal_fpi_delta,
  s.wal_buffers_full - coalesce(b.wal_buffers_full, 0) AS wal_buffers_full_delta,
  left(s.query, 200) AS query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
LEFT JOIN diag_pgss_before b
  ON b.userid = s.userid
 AND b.dbid = s.dbid
 AND b.toplevel = s.toplevel
 AND b.queryid = s.queryid
WHERE ${PGSS_FILTER}
  AND s.wal_bytes > coalesce(b.wal_bytes, 0)
ORDER BY s.wal_bytes - coalesce(b.wal_bytes, 0) DESC
LIMIT 15;
\x off

\echo
\echo '── top queries by temp in window ──'
\x on
SELECT
  s.queryid,
  (b.queryid IS NULL) AS new_in_window,
  s.calls - coalesce(b.calls, 0) AS calls_delta,
  s.temp_blks_written - coalesce(b.temp_blks_written, 0) AS temp_written_delta,
  s.temp_blks_read - coalesce(b.temp_blks_read, 0) AS temp_read_delta,
  round((s.total_exec_time - coalesce(b.total_exec_time, 0))::numeric, 1) AS exec_ms_delta,
  left(s.query, 200) AS query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
LEFT JOIN diag_pgss_before b
  ON b.userid = s.userid
 AND b.dbid = s.dbid
 AND b.toplevel = s.toplevel
 AND b.queryid = s.queryid
WHERE ${PGSS_FILTER}
  AND (s.temp_blks_written > coalesce(b.temp_blks_written, 0)
       OR s.temp_blks_read > coalesce(b.temp_blks_read, 0))
ORDER BY (s.temp_blks_written - coalesce(b.temp_blks_written, 0))
       + (s.temp_blks_read - coalesce(b.temp_blks_read, 0)) DESC
LIMIT 15;
\x off

\echo
\echo '── top offenders this run (window evidence) ──'
\echo '   (ranked by backend-samples, then window exec time;'
\echo '    next step per row: ./pg-diagnose.sh --deep-queryid=<queryid>)'
\x on
WITH samp AS (
  SELECT query_id, count(*) AS backend_samples
  FROM diag_samples
  WHERE query_id IS NOT NULL
  GROUP BY query_id
),
delta AS (
  SELECT
    s.queryid,
    s.calls - coalesce(b.calls, 0) AS calls_delta,
    s.total_exec_time - coalesce(b.total_exec_time, 0) AS exec_ms_delta,
    s.shared_blks_read - coalesce(b.shared_blks_read, 0) AS blks_read_delta,
    s.temp_blks_written - coalesce(b.temp_blks_written, 0) AS temp_written_delta,
    s.wal_bytes - coalesce(b.wal_bytes, 0) AS wal_bytes_delta,
    left(s.query, 200) AS query
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  LEFT JOIN diag_pgss_before b
    ON b.userid = s.userid
   AND b.dbid = s.dbid
   AND b.toplevel = s.toplevel
   AND b.queryid = s.queryid
  WHERE ${PGSS_FILTER}
)
SELECT
  coalesce(d.queryid, sa.query_id) AS queryid,
  coalesce(sa.backend_samples, 0) AS backend_samples,
  round(coalesce(d.exec_ms_delta, 0)::numeric, 1) AS exec_ms_delta,
  coalesce(d.calls_delta, 0) AS calls_delta,
  coalesce(d.blks_read_delta, 0) AS blks_read_delta,
  coalesce(d.temp_written_delta, 0) AS temp_written_delta,
  pg_size_pretty(coalesce(d.wal_bytes_delta, 0)::bigint) AS wal_delta,
  coalesce(d.query, '(not in pg_stat_statements)') AS query
FROM delta d
FULL JOIN samp sa ON sa.query_id = d.queryid
WHERE coalesce(sa.backend_samples, 0) > 0
   OR coalesce(d.exec_ms_delta, 0) > 1000
   OR coalesce(d.temp_written_delta, 0) > 0
ORDER BY coalesce(sa.backend_samples, 0) DESC,
         coalesce(d.exec_ms_delta, 0) DESC
LIMIT 10;
\x off
\endif

\o ${VERDICT_FILE}
\pset format unaligned
\pset tuples_only on

WITH wait_summary AS (
  SELECT wait_type,
         count(*) AS backend_samples,
         round(100.0 * count(*) / NULLIF(sum(count(*)) OVER (), 0), 1) AS pct
  FROM diag_samples
  GROUP BY wait_type
  ORDER BY backend_samples DESC
  LIMIT 1
),
top_sampled AS (
  SELECT query_key,
         coalesce(max(query_id)::text, 'no query_id') AS query_id,
         count(*) AS backend_samples,
         left(max(query), 200) AS query
  FROM diag_samples
  GROUP BY query_key
  ORDER BY backend_samples DESC
  LIMIT 1
)
SELECT verdict
FROM (
  SELECT 1 AS ord,
         '  dominant wait: ' || w.wait_type || ' (' || w.pct
         || '% of backend-samples; CPU = running, not waiting)' AS verdict
  FROM wait_summary w
  UNION ALL
  SELECT 2,
         '  top sampled query: queryid=' || t.query_id || ' — '
         || t.backend_samples || ' backend-samples' || E'\n      ' || t.query
  FROM top_sampled t
) v
ORDER BY ord;

SELECT '  ⚠ low sample count (' || count(*) || ' backend-sample(s) total) — the sampled'
  || E' verdict above is weak;\n    prefer the exec-time line below, or re-run with'
  || ' SAMPLE_SECONDS=120+ while the load is occurring'
FROM diag_samples
HAVING count(*) > 0 AND count(*) < 10;

\if :has_pgss
SELECT
  '  top query by window exec time: queryid=' || s.queryid
  || ' — ' || round((s.total_exec_time - coalesce(b.total_exec_time, 0))::numeric, 1) || ' ms'
  || E'\n      ' || left(s.query, 200) AS verdict
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
LEFT JOIN diag_pgss_before b
  ON b.userid = s.userid
 AND b.dbid = s.dbid
 AND b.toplevel = s.toplevel
 AND b.queryid = s.queryid
WHERE ${PGSS_FILTER}
  AND s.total_exec_time > coalesce(b.total_exec_time, 0)
ORDER BY s.total_exec_time - coalesce(b.total_exec_time, 0) DESC
LIMIT 1;
\endif

SELECT E'  no active workload was observed during this ${SAMPLE_SECONDS}s window\n  re-run while the problem is happening:\n    SAMPLE_SECONDS=60 $0 --only=window'
WHERE NOT EXISTS (SELECT 1 FROM diag_samples);

\pset tuples_only off
\pset format aligned
\o
DIAG_SQL
  if [[ $? -ne 0 ]]; then
    RUN_FAILED=1
    echo "   ⚠  Window phase could not run (lost the database connection mid-run — re-run the script)."
    echo "      Try: SAMPLE_SECONDS=10 $0 --only=window"
  fi
  set -e

  echo
  echo "── window verdict ──"
  echo "   (re-printed in the Summary section at the end of the report)"
  if [[ -n "$VERDICT_FILE" && -s "$VERDICT_FILE" ]]; then
    cat "$VERDICT_FILE"
  else
    echo "   ⚠  verdict unavailable — the window phase did not complete"
  fi
}