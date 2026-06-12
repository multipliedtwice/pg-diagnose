#!/usr/bin/env bash

suggestions_mode() {
  local CLEANUP_PRED="severity <> 'CLEANUP'"
  local SUGG_OUT SUGG_RC ERR_COUNT DBNAME STATS_DAYS SQL_LABEL FK_REFS_SQL FK_PLANREFS_SQL FAILED_RULES
  if [[ "$INCLUDE_CLEANUP" == "1" ]]; then
    CLEANUP_PRED="TRUE"
  fi

  SQL_LABEL="suggested SQL"
  if [[ "$PRISMA_OUT" == "1" ]]; then
    SQL_LABEL="suggested change (Prisma / SQL)"
  fi

  FK_REFS_SQL="NULL::bigint"
  FK_PLANREFS_SQL="NULL::bigint"
  if [[ "$HAS_PGSS" == "t" ]]; then
    FK_REFS_SQL="(SELECT count(*) FROM pg_stat_statements ps WHERE ps.query ~ ('\\m' || cl.relname || '\\M') AND ps.query ~ ('\\m' || fc.colname || '\\M'))"
    FK_PLANREFS_SQL="(SELECT count(DISTINCT sc.queryid) FROM sg_clauses sc WHERE (sc.relname IS NULL OR sc.relname = cl.relname) AND sc.clause ~ ('\\m' || fc.colname || '\\M'))"
  fi

  DBNAME="$(psql_get "SELECT current_database();" "unknown")"
  STATS_DAYS="$(psql_get "
  SELECT coalesce(extract(day FROM now() - coalesce(
    (SELECT stats_reset FROM pg_stat_database WHERE datname = current_database()),
    (SELECT min(stats_reset) FROM pg_stat_io)))::int::text, 'unknown');" "unknown")"

  echo
  echo "╔═══════════════════════════════════════════════════════"
  echo "║   Suggestions mode — ranked candidate actions"
  echo "║   SQL is suggested, NEVER executed"
  echo "╚═══════════════════════════════════════════════════════"
  echo "   database=${DBNAME}  pg=${PG_VERSION}  stats_age=${STATS_DAYS} day(s)"
  echo "   pg_stat_statements usable=${HAS_PGSS}  pg_read_all_stats=${HAS_READ_ALL_STATS}"
  echo "   tiers, methodology, caveats: $0 --legend  (also docs/interpreting-output.md)"
  if [[ "$INCLUDE_CLEANUP" != "1" ]]; then
    echo "   (OPTIONAL CLEANUP hidden — add --include-cleanup)"
  fi
  if [[ "$STATS_DAYS" =~ ^[0-9]+$ && "$STATS_DAYS" -lt 14 ]]; then
    echo "   ⚠  statistics cover only ${STATS_DAYS} day(s) — usage-based evidence is weak"
  fi
  if [[ "$HAS_PGSS" != "t" ]]; then
    echo "   ⚠  pg_stat_statements not usable: query-based rules skipped; catalog rules still run."
  fi

  set +e
  SUGG_OUT="$(psql_run_tolerant 2>&1 <<SUGG_SQL
SET statement_timeout = '180s';
SET lock_timeout = '2s';

SELECT /* pg-diagnose */ '${HAS_PGSS}' = 't' AS has_pgss \gset

\echo '-- rule:setup'
$(emit_sugg_setup)
$(emit_sugg_catalog)
$(emit_plan_helpers)

\if :has_pgss
$(emit_sugg_collect)
$(emit_sugg_rules_plan)
\endif

\if :has_pgss
\else
CREATE TEMP TABLE sg_clauses (queryid bigint, relname text, clause text);
\endif

$(emit_sugg_rules_catalog)
$(emit_sugg_rules_cleanup)
$(emit_sugg_output)
SUGG_SQL
)"
  SUGG_RC=$?
  set -e

  ERR_COUNT="$(count_sql_errors "$SUGG_OUT")"

  if [[ $SUGG_RC -ne 0 || "${ERR_COUNT:-0}" -gt 0 ]]; then
    RUN_FAILED=1
    FAILED_RULES="$(awk '/^-- rule:/ { r = substr($0, 9) }
      /^(psql:[^:]*:[0-9]+: )?(ERROR|FATAL|PANIC):/ { if (r != "") print r; else print "(setup)" }' \
      <<< "$SUGG_OUT" | sort -u | paste -sd ', ' -)"
    echo
    echo "╔═══════════════════════════════════════════════════════"
    echo "║  ⚠  ${ERR_COUNT:-?} SQL error(s) occurred in rule(s): ${FAILED_RULES:-unknown}"
    echo "║     Suggestions from those rules are MISSING, and the result"
    echo "║     totals below DO NOT account for them — treat counts as a"
    echo "║     lower bound only."
    echo "║     If 'setup' is listed, plan-based rules are unreliable —"
    echo "║     trust only catalog rules from this run."
    echo "╚═══════════════════════════════════════════════════════"
  fi

  printf '%s\n' "$SUGG_OUT" | grep -vE '^-- rule:' || true

  if [[ $SUGG_RC -ne 0 ]]; then
    RUN_FAILED=1
    echo "   ⚠  Suggestions mode could not complete (lost the database connection mid-run — re-run)."
  fi
}