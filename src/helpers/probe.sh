#!/usr/bin/env bash

probe_queryid_helper() {
  local CAPTURED TMP_PROBE STRIPPED
  if ! [[ "$PROBE_QUERYID" =~ ^-?[0-9]+$ ]]; then
    echo "--probe-queryid must be a bigint queryid (got: $PROBE_QUERYID)" >&2
    exit 1
  fi
  if [[ "$HAS_PGSS" != "t" ]]; then
    echo "pg_stat_statements not usable — probe mode unavailable." >&2
    exit 1
  fi

  echo
  echo "╔═══════════════════════════════════════════════════════"
  echo "║   Probe: queryid=${PROBE_QUERYID}"
  echo "║   captures a live execution's real literals, then runs"
  echo "║   EXPLAIN (ANALYZE, BUFFERS) READ ONLY — writes refused"
  echo "╚═══════════════════════════════════════════════════════"
  echo "   watching pg_stat_activity for up to ${PROBE_SECONDS}s while load is active..."

  CAPTURED="$(psql_run_tolerant -At 2>/dev/null <<PROBE_SQL
SET statement_timeout = '$((PROBE_SECONDS + 30))s';
SET stats_fetch_consistency = 'none';
CREATE TEMP TABLE probe_cap (query text);
DO \$probe\$
DECLARE found text;
BEGIN
  FOR i IN 1..$((PROBE_SECONDS * 4)) LOOP
    SELECT a.query INTO found
    FROM pg_stat_activity a
    WHERE a.pid <> pg_backend_pid()
      AND a.state = 'active'
      AND a.query_id = ${PROBE_QUERYID}
      AND a.query IS NOT NULL
      AND a.query <> '<insufficient privilege>'
    ORDER BY a.query_start
    LIMIT 1;
    IF found IS NOT NULL THEN
      INSERT INTO probe_cap VALUES (found);
      EXIT;
    END IF;
    PERFORM pg_stat_clear_snapshot();
    PERFORM pg_sleep(0.25);
  END LOOP;
END
\$probe\$;
SELECT query FROM probe_cap LIMIT 1;
PROBE_SQL
)"

  if [[ -z "$CAPTURED" ]]; then
    echo "   no live execution captured — re-run while the query is active, or raise --probe-seconds."
    RUN_FAILED=1
    return 0
  fi

  if ! grep -iqE '^[[:space:]]*(select|with)[[:space:]]' <<< "$CAPTURED"; then
    echo "   captured statement is not read-only (SELECT/WITH) — probe refuses to execute it."
    echo "   first line: $(head -1 <<< "$CAPTURED")"
    return 0
  fi

  echo
  echo "── captured statement (real literals) ──"
  printf '%s\n' "$CAPTURED"

  STRIPPED="$(sed -e 's/;[[:space:]]*$//' <<< "$CAPTURED")"
  TMP_PROBE="$(mktemp "${TMPDIR:-/tmp}/pg-diagnose-probe.XXXXXX")"
  {
    echo "BEGIN;"
    echo "SET TRANSACTION READ ONLY;"
    echo "SET LOCAL statement_timeout = '${PROBE_EXPLAIN_SECONDS}s';"
    echo "SET LOCAL lock_timeout = '2s';"
    printf 'EXPLAIN (ANALYZE, BUFFERS, VERBOSE) '
    printf '%s\n;\n' "$STRIPPED"
    echo "ROLLBACK;"
  } > "$TMP_PROBE"

  echo
  echo "── EXPLAIN (ANALYZE, BUFFERS, VERBOSE), read-only, rolled back ──"
  echo "   (per-node Buffers shows shared/temp/toast attribution — no track_io_timing needed)"
  set +e
  psql_run_tolerant -f "$TMP_PROBE" 2>&1
  local rc=$?
  set -e
  rm -f "$TMP_PROBE"
  if [[ $rc -ne 0 ]]; then
    RUN_FAILED=1
    echo "   ⚠  EXPLAIN ANALYZE failed (timeout, read-only violation, or the captured statement no longer plans)."
  fi
}