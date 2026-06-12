#!/usr/bin/env bash

phase_config() {
  run_section "wait event breakdown (evidence: live snapshot; ● none = not waiting = best CPU suspect)" "
  SELECT
    coalesce(wait_event_type, '● none (on-CPU)') AS wait_type,
    coalesce(wait_event, '-')                      AS wait_event,
    state,
    backend_type,
    count(*)                                       AS cnt
  FROM pg_stat_activity
  WHERE pid <> pg_backend_pid()
    AND coalesce(wait_event_type, '') <> 'Activity'
  GROUP BY wait_event_type, wait_event, state, backend_type
  ORDER BY wait_event_type IS NULL DESC, cnt DESC;
  "

  local HIDDEN_ACT
  HIDDEN_ACT="$(psql_get "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Activity' AND pid <> pg_backend_pid();" "0")"
  if [[ "$HIDDEN_ACT" =~ ^[0-9]+$ && "$HIDDEN_ACT" -gt 0 ]]; then
    echo "   (${HIDDEN_ACT} background backend(s) idle in main loops hidden — wait_event_type=Activity)"
  fi

  run_list "critical config values" "(none readable)" "
  SELECT '    ' || name || ' = ' || current_setting(name)
  FROM pg_settings
  WHERE name IN (
    'compute_query_id',
    'track_activities',
    'track_functions',
    'track_io_timing',
    'track_wal_io_timing',
    'track_cost_delay_timing',
    'io_method',
    'io_workers',
    'pg_stat_statements.track',
    'pg_stat_statements.track_planning',
    'pg_stat_statements.max',
    'shared_buffers',
    'effective_cache_size',
    'work_mem',
    'maintenance_work_mem',
    'wal_buffers',
    'max_wal_size',
    'checkpoint_timeout',
    'random_page_cost',
    'seq_page_cost',
    'max_parallel_workers',
    'max_parallel_workers_per_gather',
    'max_worker_processes',
    'autovacuum',
    'autovacuum_naptime',
    'autovacuum_max_workers',
    'autovacuum_vacuum_scale_factor',
    'autovacuum_analyze_scale_factor'
  )
  ORDER BY name;
  "
  echo "   (these values feed the spill, cache-fit, and WAL findings below; pgss.track semantics: $0 --legend)"

  local COMPUTE_QID TRACK_IO TRACK_WAL_IO IO_METHOD TRACK_DELAY
  local -a DO_PARAMS=()

  COMPUTE_QID="$(psql_get "SHOW compute_query_id;" "unknown")"
  if [[ "$COMPUTE_QID" == "off" ]]; then
    echo "   ⚠  compute_query_id is off (server default is 'auto'). Without query ids,"
    echo "      most per-query sections cannot join live activity to query history."
    echo "      Restore the default: compute_query_id=auto. Whether DigitalOcean's"
    echo "      configuration API exposes this setting is unverified — check:"
    echo "      doctl databases configuration get ${DB_CLUSTER_ID} --engine pg"
  fi

  if [[ "$TRACK_FUNC" == "none" ]]; then
    echo "   ⚠  track_functions=none — trigger/function timing unavailable."
    DO_PARAMS+=('"track_functions":"pl"')
  fi

  TRACK_IO="$(psql_get "SHOW track_io_timing;" "unknown")"
  if [[ "$TRACK_IO" == "off" ]]; then
    echo "   ⚠  track_io_timing=off — pg_stat_io time columns are zero (enabling adds clock-read overhead)."
    DO_PARAMS+=('"track_io_timing":"on"')
  fi

  TRACK_WAL_IO="$(psql_get "SHOW track_wal_io_timing;" "unknown")"
  if [[ "$TRACK_WAL_IO" == "off" ]]; then
    echo "   ⚠  track_wal_io_timing=off — WAL I/O time columns are zero. Not exposed in"
    echo "      DigitalOcean's configuration API; cannot be enabled on this managed cluster."
  fi

  TRACK_DELAY="$(psql_get "SHOW track_cost_delay_timing;" "unknown")"
  if [[ "$TRACK_DELAY" == "off" ]]; then
    echo "   ⚠  track_cost_delay_timing=off — vacuum/analyze delay_time is zero;"
    echo "      throttled and genuinely slow vacuums look identical."
    DO_PARAMS+=('"track_cost_delay_timing":"on"')
  fi

  IO_METHOD="$(psql_get "SHOW io_method;" "unknown")"
  if [[ "$IO_METHOD" == "worker" ]]; then
    echo "   ℹ  io_method=worker (PG18 default): shared-buffer reads are performed by"
    echo "      'io worker' backends — pg_stat_io read attribution shifts accordingly."
  fi

  if [[ "$HAS_PGSS" == "t" && "$TRACK_PLANNING" == "off" ]]; then
    echo "   ⚠  pg_stat_statements.track_planning=off — planning-time ranking will be skipped."
    DO_PARAMS+=('"pg_stat_statements.track_planning":"on"')
  fi

  if [[ ${#DO_PARAMS[@]} -gt 0 ]]; then
    local joined
    joined="$(IFS=,; printf '%s' "${DO_PARAMS[*]}")"
    echo
    echo "   Enable all flagged settings in one step. This is a DigitalOcean CLI"
    echo "   command, not SQL — run it in a local terminal where doctl is installed"
    echo "   and authenticated (these settings are cluster-level and cannot be"
    echo "   changed via SQL on DigitalOcean Managed PostgreSQL):"
    echo
    echo "     doctl databases configuration update ${DB_CLUSTER_ID} --engine pg \\"
    echo "       --config-json '{${joined}}'"
    echo
    if [[ "$DB_CLUSTER_ID" == "<cluster-id>" ]]; then
      echo "   Replace <cluster-id> with your cluster id (doctl databases list),"
      echo "   or set DB_CLUSTER_ID before running this script."
      echo
    fi
    echo "   Applies on reload (no restart). Stats accumulate forward only —"
    echo "   re-run this script after load has run for a while."
  fi

  run_list "installed extensions (versions gate some advice, e.g. pgvector >= 0.8 enables hnsw.iterative_scan)" "(none)" "
  SELECT '    ' || extname || ' ' || extversion
  FROM pg_extension
  ORDER BY extname;
  "
}