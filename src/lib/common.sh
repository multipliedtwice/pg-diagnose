#!/usr/bin/env bash

export LC_ALL=C

SAMPLE_SECONDS="${SAMPLE_SECONDS:-30}"
DB_CLUSTER_ID="${DB_CLUSTER_ID:-<cluster-id>}"
ONLY=""
OUTPUT_DIR=""
EXPLAIN_QUERYID=""
DEEP_QUERYID=""
MODE=""
INCLUDE_CLEANUP=0
SHOW_LOW_SQL=0
PRISMA_OUT=0
DEBUG=0
RUN_FAILED=0
VERDICT_FILE=""
VALID_PHASES=",config,snapshot,window,progress,history,io,tables,indexes,triggers,"

export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"

phase_enabled() {
  [[ -z "$ONLY" || ",${ONLY}," == *",$1,"* ]]
}

psql_run() {
  psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -P pager=off "$@"
}

psql_run_tolerant() {
  psql "$DATABASE_URL" -X -q -P pager=off "$@"
}

psql_get() {
  local sql="$1" fallback="${2:-}"
  local out rc
  set +e
  out="$(psql_run -At -c "$sql" 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    printf '%s' "$fallback"
  else
    printf '%s' "$out"
  fi
}

count_sql_errors() {
  grep -cE '^(psql:[^:]*:[0-9]+: )?(ERROR|FATAL|PANIC):' <<< "$1" || true
}

run_section() {
  local title="$1" sql="$2"
  shift 2
  local out rc
  set +e
  out="$(psql_run "$@" -c "$sql" 2>&1)"
  rc=$?
  set -e
  echo
  if [[ $rc -ne 0 ]]; then
    RUN_FAILED=1
    echo "── ${title} ──"
    echo "   ⚠  this section failed — the rest of the report is unaffected"
    printf '%s\n' "$out"
    return 0
  fi
  if [[ "$out" == '(0 rows)' || "$out" == *$'\n(0 rows)' ]]; then
    echo "── ${title}: none ──"
  else
    echo "── ${title} ──"
    echo
    printf '%s\n' "$out"
  fi
}

run_list() {
  local title="$1" empty_msg="$2" sql="$3"
  local out rc
  set +e
  out="$(psql_run -At -c "$sql" 2>&1)"
  rc=$?
  set -e
  echo
  echo "── ${title} ──"
  if [[ $rc -ne 0 ]]; then
    RUN_FAILED=1
    echo "   ⚠  this section failed — the rest of the report is unaffected"
    printf '%s\n' "$out"
    return 0
  fi
  if [[ -z "$out" ]]; then
    echo "   ${empty_msg}"
  else
    echo
    printf '%s\n' "$out"
  fi
}