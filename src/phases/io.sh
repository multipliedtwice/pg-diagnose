#!/usr/bin/env bash

phase_io() {
  run_section "I/O by backend type (evidence: lifetime, cluster-wide; physical reads/writes — disk vs OS page cache indistinguishable; with io_method=worker, shared-buffer reads are attributed to 'io worker')" "
  SELECT
    backend_type,
    object,
    context,
    reads,
    pg_size_pretty(read_bytes::bigint) AS read_size,
    writes,
    pg_size_pretty(write_bytes::bigint) AS write_size,
    extends,
    pg_size_pretty(extend_bytes::bigint) AS extend_size,
    hits,
    evictions,
    fsyncs,
    read_time,
    write_time,
    fsync_time
  FROM pg_stat_io
  WHERE coalesce(reads, 0) + coalesce(writes, 0)
      + coalesce(extends, 0) + coalesce(fsyncs, 0) > 0
  ORDER BY coalesce(read_bytes, 0) + coalesce(write_bytes, 0) + coalesce(extend_bytes, 0) DESC
  LIMIT 30;
  "

  run_section "WAL I/O (cluster-wide; write/fsync timing from pg_stat_io, zero-activity rows hidden)" "
  SELECT
    backend_type,
    context,
    writes,
    pg_size_pretty(write_bytes::bigint) AS write_size,
    fsyncs,
    write_time,
    fsync_time,
    stats_reset
  FROM pg_stat_io
  WHERE object = 'wal'
    AND (coalesce(writes, 0) > 0 OR coalesce(fsyncs, 0) > 0 OR coalesce(reads, 0) > 0)
  ORDER BY coalesce(write_bytes, 0) DESC, coalesce(fsyncs, 0) DESC;
  "

  run_section "WAL stats (cluster-wide; high wal_bytes / wal_buffers_full means write amplification or WAL pressure)" "
  SELECT
    wal_records,
    wal_fpi,
    pg_size_pretty(wal_bytes::bigint) AS wal_size,
    wal_buffers_full,
    stats_reset
  FROM pg_stat_wal;
  "

  run_section "checkpointer stats (cluster-wide; high req_pct or write_time indicates checkpoint storms causing CPU/I/O spikes)" "
  SELECT
    num_timed,
    num_requested,
    num_done,
    round(100.0 * num_requested / NULLIF(num_timed + num_requested, 0), 2) AS req_pct,
    round(100.0 * num_done / NULLIF(num_timed + num_requested, 0), 2) AS done_pct,
    write_time,
    sync_time,
    buffers_written,
    slru_written,
    stats_reset
  FROM pg_stat_checkpointer;
  "

  run_section "temp file pressure (high temp_bytes suggests sort/hash spills; check work_mem and query plans)" "
  SELECT
    datname,
    temp_files,
    pg_size_pretty(temp_bytes) AS temp_size,
    deadlocks,
    stats_reset
  FROM pg_stat_database
  WHERE datname = current_database();
  "

  run_section "per-table cache hit ratios" "
  SELECT
    schemaname || '.' || relname AS table,
    heap_blks_read,
    heap_blks_hit,
    round(100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0), 2) AS heap_hit_pct,
    idx_blks_read,
    idx_blks_hit,
    round(100.0 * idx_blks_hit / NULLIF(idx_blks_hit + idx_blks_read, 0), 2) AS idx_hit_pct,
    toast_blks_read,
    toast_blks_hit
  FROM pg_statio_user_tables
  WHERE coalesce(heap_blks_read, 0) + coalesce(idx_blks_read, 0) + coalesce(toast_blks_read, 0) > 0
  ORDER BY coalesce(heap_blks_read, 0) + coalesce(idx_blks_read, 0) + coalesce(toast_blks_read, 0) DESC
  LIMIT 20;
  "

  run_section "per-index cache hit ratios" "
  SELECT
    schemaname || '.' || relname AS table,
    indexrelname AS index,
    idx_blks_read,
    idx_blks_hit,
    round(100.0 * idx_blks_hit / NULLIF(idx_blks_hit + idx_blks_read, 0), 2) AS hit_pct
  FROM pg_statio_user_indexes
  WHERE idx_blks_read > 0
  ORDER BY idx_blks_read DESC
  LIMIT 20;
  "

  run_section "replication slots / WAL retention" "
  SELECT
    slot_name,
    slot_type,
    active,
    wal_status,
    safe_wal_size,
    restart_lsn,
    confirmed_flush_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)::bigint) AS retained_wal
  FROM pg_replication_slots
  ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC NULLS LAST;
  "

  run_section "replication peers (backup receivers annotated — their replay_lag grows by design)" "
  SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    replay_lsn,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint) AS replay_lag_bytes,
    write_lag,
    flush_lag,
    replay_lag,
    CASE WHEN application_name ~* 'pghoard|wal-g|wal_g|barman|pgbackrest|pg_receivewal'
         THEN 'backup receiver — does not replay; flush_lag is the meaningful metric'
         ELSE '' END AS note
  FROM pg_stat_replication;
  "
}