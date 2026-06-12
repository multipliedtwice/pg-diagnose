#!/usr/bin/env bash

detect_capabilities() {
  if ! psql_run -At -c "SELECT 1;" >/dev/null 2>&1; then
    echo "could not connect to the database — check DATABASE_URL (host, port, user, password, sslmode)" >&2
    echo "expected form: postgresql://user:pass@host:port/db?sslmode=require" >&2
    exit 1
  fi

  STARTUP="$(psql_run -At -F '|' -c "
SELECT current_setting('server_version'),
       current_setting('server_version_num'),
       current_setting('track_functions'),
       coalesce(current_setting('pg_stat_statements.track_planning', true), 'unknown'),
       pg_has_role(current_user, 'pg_read_all_stats', 'usage');
" | head -1)"
  IFS='|' read -r PG_VERSION PG_VNUM TRACK_FUNC TRACK_PLANNING HAS_READ_ALL_STATS <<< "$STARTUP"

  if [[ "$PG_VNUM" -lt 180000 ]]; then
    echo "PostgreSQL 18+ required (server reports: ${PG_VERSION})" >&2
    exit 1
  fi

  HAS_PGSS="f"
  psql_run -At -c "SELECT count(*) FROM pg_stat_statements;" >/dev/null 2>&1 && HAS_PGSS="t"
  if [[ "$HAS_PGSS" != "t" ]]; then
    TRACK_PLANNING="unknown"
  fi

  PGSS_FILTER="s.query NOT LIKE '%pg-diagnose%' AND s.query !~ '\mdiag_' AND s.query NOT LIKE '%pg\_stat%' AND s.query NOT LIKE '%pg\_temp%'"
}