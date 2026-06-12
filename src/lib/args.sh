#!/usr/bin/env bash

print_usage_text() {
  cat <<'USAGE'
pg-diagnose.sh — read-only PostgreSQL CPU/performance diagnosis (PostgreSQL 18+)

start here (no DBA knowledge needed):
  1. DATABASE_URL=postgresql://... ./pg-diagnose.sh
     then read the "Summary" section at the very end of the output first
  2. ./pg-diagnose.sh --mode=suggestions
     ranked candidate actions — nothing is ever executed automatically
  3. ./pg-diagnose.sh --deep-queryid=<id>
     evidence for one query, using a queryid from steps 1-2
  4. ./pg-diagnose.sh --probe-queryid=<id>
     measured plan with no setup: captures a live execution's real literals
     and runs EXPLAIN (ANALYZE, BUFFERS) read-only

environment variables:
  DATABASE_URL     required, e.g. postgresql://user:pass@host:port/db?sslmode=require
  SAMPLE_SECONDS   diagnostic window length in seconds (default 30, max 600)
  PROBE_SECONDS    how long --probe-queryid watches for a live execution
                   (default 45, max 600; also settable via --probe-seconds)
  PROBE_EXPLAIN_SECONDS  statement_timeout for the probe's EXPLAIN ANALYZE
                   (default 180; bare integer seconds, no suffix)
  DB_CLUSTER_ID    DigitalOcean cluster id, used only to print doctl commands

usage:
  ./pg-diagnose.sh                          full run (all phases)
  ./pg-diagnose.sh --only=window,history    run selected phases only
                                            phases: config snapshot window progress
                                                    history io tables indexes triggers
  ./pg-diagnose.sh --mode=suggestions       ranked candidate actions (SQL never executed)
  ./pg-diagnose.sh --mode=prisma            same suggestions, with index changes
                                            rendered as Prisma schema (@@index) where
                                            expressible; raw SQL kept alongside
  ./pg-diagnose.sh --mode=suggestions --include-cleanup
                                            also show optional-cleanup suggestions
                                            (works with --mode=prisma too)
  ./pg-diagnose.sh --mode=suggestions --show-low-confidence-sql
                                            show candidate SQL for low-confidence
                                            findings (works with --mode=prisma too)
  ./pg-diagnose.sh --explain-queryid=ID     print stored statement text for one queryid
  ./pg-diagnose.sh --deep-queryid=ID        per-query evidence for index/query design
  ./pg-diagnose.sh --probe-queryid=ID       capture a live execution's real literals
                                            and run EXPLAIN (ANALYZE, BUFFERS) read-only
                                            (writes refused; needs the query to be active)
  ./pg-diagnose.sh --probe-queryid=ID --probe-seconds=N
                                            watch up to N seconds for a live execution
                                            (default 45, max 600)
  ./pg-diagnose.sh --legend                 print evidence classes, suggestion tiers,
                                            and methodology notes (no DB connection)
  ./pg-diagnose.sh --output-dir=DIR         write a log of the run (off by default;
                                            logs contain query text, usernames, and
                                            client addresses — last 5 logs kept)
  ./pg-diagnose.sh --help                   this text

--mode, --explain-queryid, --deep-queryid, and --probe-queryid are mutually exclusive.
--include-cleanup and --show-low-confidence-sql require --mode.
--probe-seconds requires --probe-queryid.
The script only reads statistics. It never executes suggested SQL or modifies data;
--probe-queryid runs EXPLAIN ANALYZE on read-only (SELECT/WITH) statements inside a
READ ONLY transaction that is always rolled back.
USAGE
}

usage() {
  local rc="${1:-1}"
  if [[ "$rc" -eq 0 ]]; then
    print_usage_text
  else
    print_usage_text >&2
  fi
  exit "$rc"
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --help|-h) usage 0 ;;
      --legend) print_legend; exit 0 ;;
      --only=*) ONLY="${arg#--only=}" ;;
      --output-dir=*) OUTPUT_DIR="${arg#--output-dir=}" ;;
      --explain-queryid=*) EXPLAIN_QUERYID="${arg#--explain-queryid=}" ;;
      --deep-queryid=*) DEEP_QUERYID="${arg#--deep-queryid=}" ;;
      --probe-queryid=*) PROBE_QUERYID="${arg#--probe-queryid=}" ;;
      --probe-seconds=*) PROBE_SECONDS="${arg#--probe-seconds=}" ;;
      --explain-sql=*) EXPLAIN_SQL_FILE="${arg#--explain-sql=}" ;;
      --mode=*) MODE="${arg#--mode=}" ;;
      --include-cleanup) INCLUDE_CLEANUP=1 ;;
      --show-low-confidence-sql) SHOW_LOW_SQL=1 ;;
      *) usage ;;
    esac
  done

  if [[ -n "$MODE" && "$MODE" != "suggestions" && "$MODE" != "prisma" ]]; then
    echo "unknown mode: ${MODE}" >&2
    usage
  fi
  if [[ "$MODE" == "prisma" ]]; then
    PRISMA_OUT=1
  fi

  if [[ -z "$MODE" ]]; then
    if [[ "$INCLUDE_CLEANUP" == "1" || "$SHOW_LOW_SQL" == "1" ]]; then
      echo "--include-cleanup and --show-low-confidence-sql require --mode=suggestions or --mode=prisma" >&2
      usage
    fi
  fi

  if [[ -n "$EXPLAIN_SQL_FILE" && -z "$DEEP_QUERYID" ]]; then
    echo "--explain-sql requires --deep-queryid=<id>" >&2
    usage
  fi

  if [[ "$PROBE_SECONDS" != "45" && -z "$PROBE_QUERYID" ]]; then
    echo "--probe-seconds requires --probe-queryid=<id>" >&2
    usage
  fi

  if ! [[ "$PROBE_SECONDS" =~ ^[0-9]+$ ]] || [[ "$PROBE_SECONDS" -eq 0 ]]; then
    echo "--probe-seconds must be a positive integer (got: $PROBE_SECONDS)" >&2
    exit 1
  fi
  if [[ "$PROBE_SECONDS" -gt 600 ]]; then
    echo "--probe-seconds must be <= 600 (got: $PROBE_SECONDS)" >&2
    exit 1
  fi

  local exclusive=0
  if [[ -n "$MODE" ]]; then exclusive=$((exclusive + 1)); fi
  if [[ -n "$EXPLAIN_QUERYID" ]]; then exclusive=$((exclusive + 1)); fi
  if [[ -n "$DEEP_QUERYID" ]]; then exclusive=$((exclusive + 1)); fi
  if [[ -n "$PROBE_QUERYID" ]]; then exclusive=$((exclusive + 1)); fi
  if [[ "$exclusive" -gt 1 ]]; then
    echo "--mode, --explain-queryid, --deep-queryid, and --probe-queryid are mutually exclusive" >&2
    usage
  fi
  if [[ -n "$ONLY" && "$exclusive" -gt 0 ]]; then
    echo "--only applies to full runs only" >&2
    usage
  fi

  if [[ -n "$ONLY" ]]; then
    IFS=',' read -ra _phases <<< "$ONLY"
    for p in "${_phases[@]}"; do
      if [[ "$VALID_PHASES" != *",${p},"* ]]; then
        echo "unknown phase in --only: ${p}" >&2
        usage
      fi
    done
  fi

  if ! [[ "$SAMPLE_SECONDS" =~ ^[0-9]+$ ]] || [[ "$SAMPLE_SECONDS" -eq 0 ]]; then
    echo "SAMPLE_SECONDS must be a positive integer (got: $SAMPLE_SECONDS)" >&2
    exit 1
  fi

  if [[ "$SAMPLE_SECONDS" -gt 600 ]]; then
    echo "SAMPLE_SECONDS must be <= 600 (got: $SAMPLE_SECONDS)" >&2
    exit 1
  fi

  if [[ "$SAMPLE_SECONDS" -lt 10 ]]; then
    echo "note: SAMPLE_SECONDS=${SAMPLE_SECONDS} is very short — window evidence may miss intermittent load" >&2
  fi
}