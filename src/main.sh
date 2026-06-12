#!/usr/bin/env bash

main() {
  if [[ -n "$EXPLAIN_QUERYID" ]]; then
    explain_queryid_helper
    return "$RUN_FAILED"
  fi
  if [[ -n "$DEEP_QUERYID" ]]; then
    deep_queryid_helper
    return "$RUN_FAILED"
  fi
  if [[ "$MODE" == "suggestions" || "$MODE" == "prisma" ]]; then
    suggestions_mode
    return "$RUN_FAILED"
  fi

  print_banner

  if phase_enabled config;   then phase_config;   fi
  if phase_enabled snapshot; then phase_snapshot; fi
  if phase_enabled window;   then phase_window;   fi
  if phase_enabled progress; then phase_progress; fi
  if phase_enabled history;  then phase_history;  fi
  if phase_enabled io;       then phase_io;       fi
  if phase_enabled tables;   then phase_tables;   fi
  if phase_enabled indexes;  then phase_indexes;  fi
  if phase_enabled triggers; then phase_triggers; fi

  echo
  echo "╔═══════════════════════════════════════════════════════"
  echo "║   Summary"
  echo "╚═══════════════════════════════════════════════════════"
  if [[ -n "$VERDICT_FILE" && -s "$VERDICT_FILE" ]]; then
    cat "$VERDICT_FILE"
  else
    echo "  no window verdict available — the window phase did not run or saw no data"
  fi
  echo
  echo "  next steps:"
  echo "    ranked candidate actions:   $0 --mode=suggestions"
  echo "    one query in depth:         $0 --deep-queryid=<queryid>"
  if [[ "$RUN_FAILED" -ne 0 ]]; then
    echo
    echo "  ⚠  one or more sections failed — the report above is incomplete (exit code 1)"
  fi
  return "$RUN_FAILED"
}

run_cli() {
  parse_args "$@"

  : "${DATABASE_URL:?DATABASE_URL is required, e.g. postgresql://user:pass@host:port/db?sslmode=require}"

  detect_capabilities

  VERDICT_FILE="$(mktemp "${TMPDIR:-/tmp}/pg-diagnose-verdict.XXXXXX")"
  trap 'rm -f "$VERDICT_FILE"' EXIT

  if [[ -n "$OUTPUT_DIR" ]]; then
    if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
      echo "⚠  cannot create log directory ${OUTPUT_DIR} — continuing without logging" >&2
      OUTPUT_DIR=""
    fi
  fi

  if [[ -n "$OUTPUT_DIR" ]]; then
    KEEP_N=0
    while IFS= read -r OLD_LOG; do
      KEEP_N=$((KEEP_N + 1))
      if [[ $KEEP_N -gt 4 ]]; then rm -f "$OLD_LOG"; fi
    done < <(ls -1t "$OUTPUT_DIR"/diag-*.txt 2>/dev/null)
    echo "note: the log will contain query text, usernames, application names, and client addresses" >&2
    LOG_FILE="${OUTPUT_DIR}/diag-$(date +%Y%m%d-%H%M%S).txt"
    local rc=0
    set +e
    main 2>&1 | tee "$LOG_FILE"
    rc=$?
    set -e
    echo
    echo "log written: ${LOG_FILE}"
    return "$rc"
  fi

  main
}
