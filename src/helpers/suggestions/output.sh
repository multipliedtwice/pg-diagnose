#!/usr/bin/env bash

emit_sugg_output() {
  cat <<OUTPUT_SQL
\echo '-- rule:postprocess'
UPDATE sugg SET
  confidence = CASE WHEN confidence = 'HIGH' THEN 'MEDIUM' ELSE confidence END,
  detail = concat_ws('; ', detail,
    'multiple ordered-index suggestions target this table — consolidate query shapes before adding all of them')
WHERE category = 'Missing index for sorted pagination'
  AND objname IN (
    SELECT objname FROM sugg
    WHERE category = 'Missing index for sorted pagination'
    GROUP BY objname
    HAVING count(*) > 2
  );

\echo '-- rule:output'
\echo
\echo '── result ──'
\pset format unaligned
\pset tuples_only on

SELECT '  ' ||
  CASE WHEN count(*) FILTER (WHERE ${CLEANUP_PRED}) = 0
    THEN 'no visible suggestions — workload clean, thresholds not met, or all items are hidden cleanup'
    ELSE (count(*) FILTER (WHERE ${CLEANUP_PRED}))::text || ' suggestion(s) below — nothing was executed'
  END
FROM sugg;

SELECT format('  %s: %s suggestion(s)', severity, count(*))
FROM sugg
GROUP BY severity
ORDER BY min(sort);

SELECT '  ' || count(*) || ' OPTIONAL CLEANUP suggestion(s) ' ||
  CASE WHEN ${INCLUDE_CLEANUP} = 1 THEN 'included below'
       ELSE 'hidden — rerun with --mode=suggestions --include-cleanup' END
FROM sugg
WHERE severity = 'CLEANUP'
HAVING count(*) > 0;

\echo
\echo '── ranked suggestions (grouped by category) ──'

WITH vis AS (
  SELECT s.*,
    CASE WHEN s.severity = 'CLEANUP' THEN 'OPTIONAL CLEANUP'
         WHEN s.confidence = 'HIGH' THEN 'TEST FIRST'
         WHEN s.confidence = 'MEDIUM' THEN 'VERIFY FIRST'
         ELSE 'INVESTIGATE ONLY' END AS next_action,
    CASE WHEN s.severity = 'CLEANUP' THEN 'confidence=' || s.confidence
         ELSE 'severity=' || s.severity END AS rank_label,
    CASE WHEN s.confidence = 'LOW'
              AND s.severity <> 'CLEANUP'
              AND s.suggested_sql IS NOT NULL
              AND ${SHOW_LOW_SQL} = 0
         THEN '(hidden — rerun with --show-low-confidence-sql)'
         WHEN ${PRISMA_OUT} = 1 AND s.suggested_sql IS NOT NULL
         THEN pg_temp.to_prisma_block(s.suggested_sql)
         ELSE s.suggested_sql END AS sql_display,
    row_number() OVER (ORDER BY
      CASE WHEN s.severity = 'CLEANUP' THEN 3
           WHEN s.confidence = 'HIGH' THEN 0
           WHEN s.confidence = 'MEDIUM' THEN 1
           ELSE 2 END,
      s.sort,
      CASE s.severity WHEN 'HIGH' THEN 0 WHEN 'MEDIUM' THEN 1 ELSE 2 END) AS rn
  FROM sugg s
  WHERE ${CLEANUP_PRED}
),
grouped AS (
  SELECT v.category,
    coalesce(c.why, '(see evidence)') AS why,
    coalesce(c.risk, '-') AS risk,
    coalesce(c.skip_if, '-') AS skip_if,
    min(v.rn) AS first_rn,
    count(*) AS n,
    string_agg(
      format(E'   [%s] %s%s%s%s%s%s%s',
        v.next_action, v.rank_label,
        coalesce('  queryid=' || v.queryid, ''),
        coalesce(E'\n     object:   ' || v.objname, ''),
        coalesce(E'\n     note:     ' || v.detail, ''),
        coalesce(E'\n     evidence: ' || v.evidence, ''),
        E'\n     verify:   ' || v.verify_cmd,
        coalesce(E'\n     ${SQL_LABEL}:\n       ' || replace(v.sql_display, E'\n', E'\n       '), '')
      ), E'\n\n' ORDER BY v.rn) AS body
  FROM vis v
  LEFT JOIN sugg_cat c USING (category)
  GROUP BY v.category, c.why, c.risk, c.skip_if
)
SELECT format(E'\n%s. %s — %s instance(s)\n   why:  %s\n   risk: %s\n   do not apply if: %s\n\n%s',
  row_number() OVER (ORDER BY first_rn), category, n, why, risk, skip_if, body)
FROM grouped
ORDER BY first_rn;

\pset tuples_only off
\pset format aligned
OUTPUT_SQL
}