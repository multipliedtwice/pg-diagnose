#!/usr/bin/env bash

explain_queryid_helper() {
  if ! [[ "$EXPLAIN_QUERYID" =~ ^-?[0-9]+$ ]]; then
    echo "--explain-queryid must be a bigint queryid (got: $EXPLAIN_QUERYID)" >&2
    exit 1
  fi
  if [[ "$HAS_PGSS" != "t" ]]; then
    echo "pg_stat_statements not usable — cannot look up queryid." >&2
    exit 1
  fi

  echo
  echo "── stored statement for queryid=${EXPLAIN_QUERYID} ──"
  echo

  psql_run -x -c "
  SELECT
    s.queryid,
    s.calls,
    s.mean_exec_time::numeric(12,2) AS mean_ms,
    s.max_exec_time::numeric(12,2) AS max_ms,
    s.query
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid
  WHERE d.datname = current_database()
    AND s.queryid = ${EXPLAIN_QUERYID};
  "

  echo
  echo "  The stored text is normalized — \$1, \$2 placeholders instead of real values."
  echo "  Substitute representative parameter values, then run manually:"
  echo
  echo "    EXPLAIN (ANALYZE, BUFFERS, WAL, VERBOSE) <query with real params>;"
  echo
  echo "  Tip: real parameter values come from your application logs, or from"
  echo "  enabling log_min_duration_statement on the cluster."
  echo
  echo "  Note: EXPLAIN ANALYZE executes the statement. For writes, wrap in"
  echo "  BEGIN; ... ROLLBACK; — this script intentionally never auto-runs it."
}