#!/usr/bin/env bash

phase_snapshot() {
  run_list "ranked findings (evidence: live snapshot)" "none — nothing suspicious in the live snapshot" "
  WITH activity AS (
    SELECT
      count(*) FILTER (WHERE state = 'active'
                       AND wait_event_type IS NULL
                       AND pid <> pg_backend_pid())                        AS active_no_wait,
      count(*) FILTER (WHERE wait_event_type = 'Lock'
                       AND pid <> pg_backend_pid())                        AS lock_waiters,
      count(*) FILTER (WHERE wait_event_type = 'LWLock'
                       AND pid <> pg_backend_pid())                        AS lwlock_waiters,
      count(*) FILTER (WHERE state IN ('idle in transaction',
                                       'idle in transaction (aborted)')
                       AND pid <> pg_backend_pid())                        AS idle_tx,
      count(*) FILTER (WHERE backend_type = 'autovacuum worker')           AS av_workers,
      count(*) FILTER (WHERE backend_type = 'parallel worker')             AS parallel_workers,
      count(*) FILTER (WHERE pid <> pg_backend_pid())                      AS total_conn
    FROM pg_stat_activity
  ),
  blocking AS (
    SELECT count(*) AS blocked_count
    FROM pg_stat_activity
    WHERE pid <> pg_backend_pid()
      AND coalesce(array_length(pg_blocking_pids(pid), 1), 0) > 0
  ),
  cache_hit AS (
    SELECT round(100.0 * sum(heap_blks_hit)
                 / NULLIF(sum(heap_blks_hit + heap_blks_read), 0), 2) AS table_hit_pct
    FROM pg_statio_user_tables
  )
  SELECT format(E'  [%s] %s\n      evidence: %s\n      next:     %s\n',
                severity, finding, evidence, next_step)
  FROM (
    SELECT 10 AS sort, 'HIGH' AS severity,
      'Active queries with no wait event — best CPU suspect.' AS finding,
      'active_no_wait=' || active_no_wait AS evidence,
      'See the window-phase wait profile for the worst offender.' AS next_step
    FROM activity WHERE active_no_wait > 0

    UNION ALL
    SELECT 15, 'HIGH',
      'High contention on internal shared-memory locks (LWLock) — multiple processes are using the same shared structures at once.' AS finding,
      'lwlock_waiters=' || lwlock_waiters AS evidence,
      'WALWrite → batch writes. buffer_mapping → check buffer churn and working-set fit before resizing.' AS next_step
    FROM activity WHERE lwlock_waiters > 2

    UNION ALL
    SELECT 20, 'HIGH',
      'Lock contention — queries blocked by other sessions.' AS finding,
      'lock_waiters=' || lock_waiters || ' blocked=' || (SELECT blocked_count FROM blocking) AS evidence,
      'See the lock graph below for relation and lock mode.' AS next_step
    FROM activity, blocking
    WHERE (SELECT blocked_count FROM blocking) > 0 OR lock_waiters > 0

    UNION ALL
    SELECT 30, 'MEDIUM',
      'Idle transactions holding resources.' AS finding,
      'idle_in_transaction=' || idle_tx AS evidence,
      'See idle transactions below. Fix the app path that leaves transactions open.' AS next_step
    FROM activity WHERE idle_tx > 0

    UNION ALL
    SELECT 40, 'MEDIUM',
      'Autovacuum workers active.' AS finding,
      'workers=' || av_workers AS evidence,
      'Check progress views, dead tuple rate, and XID age before concluding it is struggling.' AS next_step
    FROM activity WHERE av_workers > 0

    UNION ALL
    SELECT 45, 'MEDIUM',
      'Parallel query workers consuming CPU cores.' AS finding,
      'parallel_workers=' || parallel_workers AS evidence,
      'Inspect the leader query first. Lowering max_parallel_workers_per_gather may help but is not the automatic fix.' AS next_step
    FROM activity WHERE parallel_workers > 2

    UNION ALL
    SELECT 60, 'LOW',
      'Table cache hit ratio below 95% (lifetime counters, not window) — queries reading from disk.' AS finding,
      'hit_pct=' || coalesce((SELECT table_hit_pct FROM cache_hit)::text, 'N/A') || '%' AS evidence,
      'Add indexes for heavy-read tables or consider resizing the cluster.' AS next_step
    FROM cache_hit
    WHERE table_hit_pct IS NOT NULL AND table_hit_pct < 95
  ) x
  ORDER BY sort;
  "

  run_section "active queries (no wait)" "
  SELECT
    pid,
    query_id,
    backend_type,
    usename,
    application_name,
    client_addr,
    now() - query_start AS duration,
    left(query, 200) AS query
  FROM pg_stat_activity
  WHERE state = 'active'
    AND wait_event_type IS NULL
    AND pid <> pg_backend_pid()
  ORDER BY query_start
  LIMIT 20;
  " -x

  run_section "load attribution by app/user/client" "
  SELECT
    usename,
    application_name,
    client_addr,
    state,
    coalesce(wait_event_type, 'CPU') AS wait_type,
    count(*) AS connections,
    count(*) FILTER (WHERE state = 'active') AS active,
    max(now() - query_start) FILTER (WHERE query_start IS NOT NULL) AS max_query_age,
    max(now() - xact_start) FILTER (WHERE xact_start IS NOT NULL) AS max_xact_age
  FROM pg_stat_activity
  WHERE pid <> pg_backend_pid()
  GROUP BY usename, application_name, client_addr, state, coalesce(wait_event_type, 'CPU')
  ORDER BY active DESC, connections DESC;
  "

  echo
  echo "── active backend WAL + I/O delta (5s, per-backend, PG18) ──"
  echo "   (WAL and physical I/O generated over 5 seconds by currently active backends;"
  echo "    idle main-loop daemons excluded)"
  echo "   measuring for 5 seconds — output appears when done..."
  echo

  set +e
  psql_run_tolerant <<'BACKEND_SQL'
SET statement_timeout = '60s';
SET lock_timeout = '2s';
SET stats_fetch_consistency = 'none';

/* pg-diagnose */
CREATE TEMP TABLE diag_backend_before AS
SELECT
  a.pid,
  a.query_id,
  a.backend_type,
  a.query_start,
  left(a.query, 200) AS query,
  w.wal_records,
  w.wal_fpi,
  w.wal_bytes,
  io.reads,
  io.read_bytes,
  io.writes,
  io.write_bytes
FROM pg_stat_activity a
LEFT JOIN LATERAL pg_stat_get_backend_wal(a.pid) w ON true
LEFT JOIN LATERAL (
  SELECT
    sum(reads) AS reads,
    sum(coalesce(read_bytes, 0)) AS read_bytes,
    sum(writes) AS writes,
    sum(coalesce(write_bytes, 0)) AS write_bytes
  FROM pg_stat_get_backend_io(a.pid)
) io ON true
WHERE a.state = 'active'
  AND coalesce(a.wait_event_type, '') <> 'Activity'
  AND a.pid <> pg_backend_pid();

SELECT
  count(*) AS active_backends,
  count(*) FILTER (WHERE wal_records IS NULL) AS stats_not_visible
FROM diag_backend_before;

SELECT pg_sleep(5) \gset

\x on
SELECT
  b.pid,
  b.query_id,
  b.backend_type,
  clock_timestamp() - b.query_start AS duration,
  w.wal_records - b.wal_records AS wal_records_delta,
  w.wal_fpi - b.wal_fpi AS wal_fpi_delta,
  pg_size_pretty((w.wal_bytes - b.wal_bytes)::bigint) AS wal_delta,
  io.reads - b.reads AS reads_delta,
  pg_size_pretty((io.read_bytes - b.read_bytes)::bigint) AS read_delta,
  io.writes - b.writes AS writes_delta,
  pg_size_pretty((io.write_bytes - b.write_bytes)::bigint) AS write_delta,
  b.query
FROM diag_backend_before b
LEFT JOIN LATERAL pg_stat_get_backend_wal(b.pid) w ON true
LEFT JOIN LATERAL (
  SELECT
    sum(reads) AS reads,
    sum(coalesce(read_bytes, 0)) AS read_bytes,
    sum(writes) AS writes,
    sum(coalesce(write_bytes, 0)) AS write_bytes
  FROM pg_stat_get_backend_io(b.pid)
) io ON true
WHERE coalesce(w.wal_bytes, 0)   > coalesce(b.wal_bytes, 0)
   OR coalesce(w.wal_records, 0) > coalesce(b.wal_records, 0)
   OR coalesce(io.read_bytes, 0) > coalesce(b.read_bytes, 0)
   OR coalesce(io.write_bytes, 0) > coalesce(b.write_bytes, 0)
ORDER BY (coalesce(w.wal_bytes, 0) - coalesce(b.wal_bytes, 0))
       + (coalesce(io.read_bytes, 0) - coalesce(b.read_bytes, 0)) DESC
LIMIT 20;
\x off
BACKEND_SQL
  if [[ $? -ne 0 ]]; then
    echo "   ⚠  Could not fetch per-backend WAL/I-O delta stats."
  fi
  set -e
  if [[ "$HAS_READ_ALL_STATS" != "t" ]]; then
    echo "   (stats_not_visible > 0 above means a visibility limit — current role"
    echo "    lacks pg_read_all_stats — not idle backends)"
  fi

  run_section "lock graph (relation + mode)" "
  SELECT
    blocked.pid AS blocked_pid,
    blocked.query_id AS blocked_qid,
    blocked_locks.locktype,
    blocked_locks.mode AS blocked_mode,
    blocked_locks.relation::regclass AS relation,
    blocking.pid AS blocking_pid,
    blocking.query_id AS blocking_qid,
    blocking_locks.mode AS blocking_mode,
    now() - blocked.query_start AS blocked_for,
    left(blocked.query, 200) AS blocked_query,
    left(blocking.query, 200) AS blocking_query
  FROM pg_locks blocked_locks
  JOIN pg_stat_activity blocked
    ON blocked.pid = blocked_locks.pid
  JOIN pg_locks blocking_locks
    ON blocking_locks.locktype = blocked_locks.locktype
   AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
   AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
   AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
   AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
   AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
   AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
   AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
   AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
   AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
   AND blocking_locks.pid <> blocked_locks.pid
  JOIN pg_stat_activity blocking
    ON blocking.pid = blocking_locks.pid
  WHERE NOT blocked_locks.granted
    AND blocking_locks.granted
  ORDER BY blocked.query_start
  LIMIT 30;
  " -x

  run_section "idle transactions" "
  SELECT
    pid,
    query_id,
    now() - xact_start    AS xact_age,
    now() - state_change  AS idle_for,
    usename,
    application_name,
    client_addr,
    left(query, 200)      AS last_query
  FROM pg_stat_activity
  WHERE state IN ('idle in transaction', 'idle in transaction (aborted)')
  ORDER BY xact_start ASC
  LIMIT 20;
  " -x

  run_section "parallel workers" "
  SELECT
    pid, leader_pid, backend_type, state,
    wait_event_type, wait_event,
    now() - query_start AS duration,
    query_id,
    left(query, 200) AS query
  FROM pg_stat_activity
  WHERE leader_pid IS NOT NULL
     OR backend_type = 'parallel worker'
  ORDER BY leader_pid NULLS LAST, pid;
  " -x
}
