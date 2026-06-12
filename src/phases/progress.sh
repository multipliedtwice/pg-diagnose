#!/usr/bin/env bash

phase_progress() {
  run_section "progress: vacuum (delay_ms needs track_cost_delay_timing)" "
  SELECT
    p.pid,
    a.backend_type,
    p.relid::regclass AS table,
    p.phase,
    p.heap_blks_total,
    p.heap_blks_scanned,
    p.heap_blks_vacuumed,
    round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 2) AS scan_pct,
    p.indexes_total,
    p.indexes_processed,
    p.delay_time::int AS delay_ms,
    now() - a.query_start AS duration
  FROM pg_stat_progress_vacuum p
  JOIN pg_stat_activity a ON a.pid = p.pid
  ORDER BY a.query_start;
  "

  run_section "progress: analyze" "
  SELECT
    p.pid,
    p.relid::regclass AS table,
    p.phase,
    p.sample_blks_total,
    p.sample_blks_scanned,
    round(100.0 * p.sample_blks_scanned / NULLIF(p.sample_blks_total, 0), 2) AS scan_pct,
    p.child_tables_total,
    p.child_tables_done,
    p.delay_time::int AS delay_ms,
    now() - a.query_start AS duration
  FROM pg_stat_progress_analyze p
  JOIN pg_stat_activity a ON a.pid = p.pid
  ORDER BY a.query_start;
  "

  run_section "progress: create index / reindex" "
  SELECT
    p.pid,
    p.relid::regclass AS table,
    p.index_relid::regclass AS index,
    p.command,
    p.phase,
    p.blocks_done,
    p.blocks_total,
    round(100.0 * p.blocks_done / NULLIF(p.blocks_total, 0), 2) AS blocks_pct,
    p.tuples_done,
    p.tuples_total,
    p.lockers_done,
    p.lockers_total,
    p.current_locker_pid
  FROM pg_stat_progress_create_index p
  ORDER BY p.pid;
  "

  run_section "progress: cluster / vacuum full" "
  SELECT
    pid,
    relid::regclass AS table,
    command,
    phase,
    heap_blks_total,
    heap_blks_scanned,
    round(100.0 * heap_blks_scanned / NULLIF(heap_blks_total, 0), 2) AS scan_pct,
    heap_tuples_scanned,
    heap_tuples_written,
    index_rebuild_count
  FROM pg_stat_progress_cluster
  ORDER BY pid;
  "

  run_section "progress: copy" "
  SELECT
    p.pid,
    p.relid::regclass AS table,
    p.command,
    p.type,
    pg_size_pretty(p.bytes_processed) AS processed,
    pg_size_pretty(NULLIF(p.bytes_total, 0)) AS total,
    p.tuples_processed,
    p.tuples_excluded,
    p.tuples_skipped,
    now() - a.query_start AS duration
  FROM pg_stat_progress_copy p
  JOIN pg_stat_activity a ON a.pid = p.pid
  ORDER BY a.query_start;
  "
}
