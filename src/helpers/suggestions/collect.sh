#!/usr/bin/env bash

emit_sugg_collect() {
  cat <<COLLECT_SQL
CREATE TEMP TABLE sg_workload AS
SELECT coalesce(sum(s.total_exec_time), 0) AS total_ms
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
WHERE ${PGSS_FILTER};

CREATE TEMP TABLE sg_base AS
SELECT s.queryid, s.calls, s.total_exec_time, s.mean_exec_time, s.temp_blks_written, s.query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
WHERE s.calls > 5
  AND s.query ~* '^[[:space:]]*(select|with|update|delete|insert)'
  AND ${PGSS_FILTER};

CREATE TEMP TABLE sg_top AS
SELECT DISTINCT ON (queryid)
  queryid, calls, total_exec_time, mean_exec_time, temp_blks_written, query
FROM (
  (SELECT * FROM sg_base ORDER BY total_exec_time DESC LIMIT 15)
  UNION ALL
  (SELECT * FROM sg_base WHERE mean_exec_time > 50 ORDER BY mean_exec_time DESC LIMIT 15)
  UNION ALL
  (SELECT * FROM sg_base WHERE temp_blks_written > 1000 ORDER BY temp_blks_written DESC LIMIT 10)
) u
ORDER BY queryid;

CREATE TEMP TABLE sg_plans AS
SELECT t.queryid, t.calls, t.total_exec_time, t.mean_exec_time, t.query,
       e.plan, e.planmode, e.err
FROM sg_top t
CROSS JOIN LATERAL pg_temp.explain_try(t.query) e;

CREATE TEMP TABLE sg_nodes AS
WITH RECURSIVE nodes(queryid, calls, total_exec_time, mean_exec_time, planmode, depth, node) AS (
  SELECT p.queryid, p.calls, p.total_exec_time, p.mean_exec_time, p.planmode, 0, p.plan -> 0 -> 'Plan'
  FROM sg_plans p
  WHERE p.plan IS NOT NULL
  UNION ALL
  SELECT n.queryid, n.calls, n.total_exec_time, n.mean_exec_time, n.planmode, n.depth + 1, child.value
  FROM nodes n
  CROSS JOIN LATERAL jsonb_array_elements(n.node -> 'Plans') AS child
  WHERE jsonb_typeof(n.node -> 'Plans') = 'array'
)
SELECT * FROM nodes;

CREATE TEMP TABLE sg_rootagg AS
SELECT DISTINCT queryid FROM sg_nodes
WHERE node ->> 'Node Type' = 'Aggregate'
  AND depth <= 3
  AND coalesce(node ->> 'Parent Relationship', '') NOT IN ('SubPlan', 'InitPlan');

CREATE TEMP TABLE sg_clauses AS
SELECT DISTINCT n.queryid,
  n.node ->> 'Relation Name' AS relname,
  concat_ws(' ',
    n.node ->> 'Index Cond',
    n.node ->> 'Recheck Cond',
    n.node ->> 'Filter',
    n.node ->> 'Join Filter',
    n.node ->> 'Hash Cond',
    n.node ->> 'Merge Cond') AS clause
FROM sg_nodes n
WHERE n.node ?| array['Index Cond','Recheck Cond','Filter','Join Filter','Hash Cond','Merge Cond'];

\echo
\echo '── plan coverage ──'
SELECT
  count(*) AS stmts_checked,
  count(*) FILTER (WHERE planmode = 'generic') AS generic_plans,
  count(*) FILTER (WHERE planmode = 'generic-rewritten') AS rewritten_generic_plans,
  count(*) FILTER (WHERE planmode = 'null-params') AS null_param_fallbacks,
  count(*) FILTER (WHERE plan IS NULL) AS unplannable
FROM sg_plans;

SELECT count(*) > 0 AS has_fallback FROM sg_plans
WHERE planmode NOT IN ('generic', 'generic-rewritten') \gset

\if :has_fallback
\echo
\echo '── statements planned via fallback or excluded from plan-based rules ──'
SELECT
  queryid,
  planmode,
  left(err, 200) AS planner_error,
  CASE WHEN plan IS NULL AND query ~ '(<->|<=>|<#>|<\+>)'
       THEN 'vector distance operator in text — ANN detection skipped, review manually'
       WHEN plan IS NULL AND query ~ '(@>|&&|<@)'
       THEN 'container operator in text — GIN detection skipped, review manually'
       ELSE '' END AS note,
  left(query, 400) AS query
FROM sg_plans
WHERE planmode NOT IN ('generic', 'generic-rewritten')
ORDER BY total_exec_time DESC;
\endif

CREATE TEMP TABLE sg_container AS
SELECT z.schemaname, z.relname, z.colname,
  count(*) AS queries,
  sum(z.total_exec_time)::bigint AS total_ms,
  sum(z.calls)::bigint AS calls,
  (array_agg(z.queryid ORDER BY z.total_exec_time DESC))[1] AS top_queryid,
  string_agg(z.queryid::text, ', ' ORDER BY z.total_exec_time DESC) AS queryids,
  max(z.pred) AS pred
FROM (
  SELECT DISTINCT ON (y.schemaname, y.relname, y.colname, y.queryid)
    y.schemaname, y.relname, y.colname, y.queryid, y.calls, y.total_exec_time, y.pred
  FROM (
    SELECT n.queryid, n.calls, n.total_exec_time,
      coalesce(n.node ->> 'Schema', 'public') AS schemaname,
      n.node ->> 'Relation Name' AS relname,
      q.pred,
      coalesce(
        trim(both '"' from (regexp_match(q.pred,
          '(?<![."A-Za-z0-9_])([A-Za-z_][A-Za-z0-9_]*|"[^"]+")[[:space:]]*(?:@>|&&|<@)'))[1]),
        trim(both '"' from (regexp_match(q.pred,
          '(?:@>|&&|<@)[[:space:]]*\(?([A-Za-z_][A-Za-z0-9_]*|"[^"]+")(?![."A-Za-z0-9_])'))[1])
      ) AS colname
    FROM sg_nodes n
    CROSS JOIN LATERAL (
      SELECT coalesce(n.node ->> 'Alias', n.node ->> 'Relation Name') AS als,
             nullif(concat_ws(' ', n.node ->> 'Filter', n.node ->> 'Recheck Cond'), '') AS rawpred
    ) al
    CROSS JOIN LATERAL (
      SELECT regexp_replace(
               regexp_replace(al.rawpred, '"' || al.als || '"\.', '', 'g'),
               '\m' || al.als || '\.', '', 'g') AS pred
    ) q
    WHERE n.node ? 'Relation Name'
      AND al.rawpred ~ '(@>|&&|<@)'
  ) y
  WHERE y.colname IS NOT NULL
  ORDER BY y.schemaname, y.relname, y.colname, y.queryid
) z
GROUP BY z.schemaname, z.relname, z.colname;

CREATE TEMP TABLE sg_like AS
SELECT z.schemaname, z.relname, z.colname,
  count(*) AS queries,
  sum(z.total_exec_time)::bigint AS total_ms,
  sum(z.calls)::bigint AS calls,
  (array_agg(z.queryid ORDER BY z.total_exec_time DESC))[1] AS top_queryid,
  string_agg(z.queryid::text, ', ' ORDER BY z.total_exec_time DESC) AS queryids,
  max(z.pred) AS pred
FROM (
  SELECT DISTINCT ON (y.schemaname, y.relname, y.colname, y.queryid)
    y.schemaname, y.relname, y.colname, y.queryid, y.calls, y.total_exec_time, y.pred
  FROM (
    SELECT n.queryid, n.calls, n.total_exec_time,
      coalesce(n.node ->> 'Schema', 'public') AS schemaname,
      n.node ->> 'Relation Name' AS relname,
      q.pred,
      (regexp_match(q.pred,
        '(?<![."A-Za-z0-9_])"?([A-Za-z_][A-Za-z0-9_]*)"?\)?[[:space:]]*(~~[*]|~~|~[*])'))[1] AS colname
    FROM sg_nodes n
    CROSS JOIN LATERAL (
      SELECT coalesce(n.node ->> 'Alias', n.node ->> 'Relation Name') AS als,
             n.node ->> 'Filter' AS rawpred
    ) al
    CROSS JOIN LATERAL (
      SELECT regexp_replace(
               regexp_replace(
                 regexp_replace(al.rawpred, '"' || al.als || '"\.', '', 'g'),
                 '\m' || al.als || '\.', '', 'g'),
               '\)?::text(\[\])?', '', 'g') AS pred
    ) q
    WHERE n.node ? 'Relation Name'
      AND al.rawpred ~ '(~~[*]|~~|~[*])'
  ) y
  WHERE y.colname IS NOT NULL
  ORDER BY y.schemaname, y.relname, y.colname, y.queryid
) z
GROUP BY z.schemaname, z.relname, z.colname;
COLLECT_SQL
}