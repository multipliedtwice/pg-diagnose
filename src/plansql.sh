#!/usr/bin/env bash

emit_plan_helpers() {
  cat <<'PLAN_HELPERS_SQL'
CREATE FUNCTION pg_temp.rewrite_typed_literals(q text) RETURNS text
LANGUAGE sql AS $fn$
  SELECT regexp_replace(q,
    '\m(interval|date|timestamp(?:[[:space:]]+with(?:out)?[[:space:]]+time[[:space:]]+zone)?|time(?:[[:space:]]+with(?:out)?[[:space:]]+time[[:space:]]+zone)?)[[:space:]]+([$][0-9]+)',
    '\2::\1', 'gi')
$fn$;

CREATE FUNCTION pg_temp.explain_try(q text, OUT plan jsonb, OUT planmode text, OUT err text)
LANGUAGE plpgsql AS $fn$
DECLARE r json;
BEGIN
  BEGIN
    EXECUTE 'EXPLAIN (GENERIC_PLAN, VERBOSE, FORMAT JSON) ' || q INTO r;
    plan := r::jsonb;
    planmode := 'generic';
    RETURN;
  EXCEPTION WHEN OTHERS THEN
    err := SQLERRM;
  END;
  BEGIN
    EXECUTE 'EXPLAIN (GENERIC_PLAN, VERBOSE, FORMAT JSON) ' || pg_temp.rewrite_typed_literals(q) INTO r;
    plan := r::jsonb;
    planmode := 'generic-rewritten';
    RETURN;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  BEGIN
    EXECUTE 'EXPLAIN (VERBOSE, FORMAT JSON) '
      || regexp_replace(q, '[$][0-9]+', 'NULL', 'g') INTO r;
    plan := r::jsonb;
    planmode := 'null-params';
    RETURN;
  EXCEPTION WHEN OTHERS THEN
    err := err || ' || null-params: ' || SQLERRM;
    planmode := 'failed';
  END;
END
$fn$;

CREATE FUNCTION pg_temp.explain_try_text(q text) RETURNS SETOF text
LANGUAGE plpgsql AS $fn$
DECLARE l text;
BEGIN
  BEGIN
    FOR l IN EXECUTE 'EXPLAIN (GENERIC_PLAN, VERBOSE) ' || q LOOP
      RETURN NEXT l;
    END LOOP;
    RETURN;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  BEGIN
    FOR l IN EXECUTE 'EXPLAIN (GENERIC_PLAN, VERBOSE) ' || pg_temp.rewrite_typed_literals(q) LOOP
      RETURN NEXT l;
    END LOOP;
    RETURN NEXT '(typed literals were rewritten to casts to obtain this plan)';
    RETURN;
  EXCEPTION WHEN OTHERS THEN
    RETURN NEXT 'generic plan unavailable: ' || SQLERRM;
  END;
END
$fn$;
PLAN_HELPERS_SQL
}