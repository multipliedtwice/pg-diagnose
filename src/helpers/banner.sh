#!/usr/bin/env bash

print_banner() {
  echo
  echo "╔═══════════════════════════════════════════════════════"
  echo "║   PostgreSQL CPU Diagnosis"
  echo "║   window=${SAMPLE_SECONDS}s  server=PostgreSQL ${PG_VERSION}"
  echo "╚═══════════════════════════════════════════════════════"
  echo
  echo "  how to read this report:"
  echo "    1. the most important output is the 'Summary' section at the very end —"
  echo "       it names the dominant wait and the heaviest query observed during this run"
  echo "    2. every section header states its evidence class:"
  echo "       window/sampled = what happened during this run (strongest)"
  echo "       live snapshot  = what is happening right now (strong)"
  echo "       lifetime       = totals since the last stats reset (medium)"
  echo "       static         = based on schema rules only, not observed behavior"
  echo "                        (weakest — verify manually)"
  echo "    3. to act on a specific query:  $0 --deep-queryid=<queryid>"
  echo "       to get ranked actions:       $0 --mode=suggestions"
  if [[ "$HAS_READ_ALL_STATS" != "t" ]]; then
    echo
    echo "  ⚠ current role lacks pg_read_all_stats: query text/query IDs of other"
    echo "    users' sessions and per-backend WAL/I-O statistics may be hidden or"
    echo "    NULL. Sections relying on them will under-report, not error."
  fi
}
