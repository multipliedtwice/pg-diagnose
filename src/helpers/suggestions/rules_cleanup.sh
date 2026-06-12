#!/usr/bin/env bash

emit_sugg_rules_cleanup() {
  cat <<'RULES_CLEANUP_SQL'
\echo '-- rule:redundant-index'
INSERT INTO sugg
SELECT
  'CLEANUP', 'MEDIUM', 'Redundant index (covered by another)',
  NULL,
  n.nspname || '.' || t.relname,
  'DROP INDEX CONCURRENTLY ' || quote_ident(n.nspname) || '.' || quote_ident(ci1.relname) || ';',
  'covering=' || ci2.relname || ' (' || pg_size_pretty(pg_relation_size(i2.indexrelid))
    || ' vs ' || pg_size_pretty(pg_relation_size(i1.indexrelid))
    || '); redundant index has ' || coalesce(ui1.idx_scan, 0) || ' recorded scans that will shift to it',
  'redundant=' || pg_get_indexdef(i1.indexrelid) || ' || covering=' || pg_get_indexdef(i2.indexrelid)
    || ' size=' || pg_size_pretty(pg_relation_size(i1.indexrelid)),
  'verify both definitions in evidence, then DROP INDEX CONCURRENTLY; never urgent',
  50
FROM pg_index i1
JOIN pg_index i2 ON i1.indrelid = i2.indrelid AND i1.indexrelid <> i2.indexrelid
JOIN pg_class ci1 ON ci1.oid = i1.indexrelid
JOIN pg_class ci2 ON ci2.oid = i2.indexrelid
JOIN pg_class t ON t.oid = i1.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
LEFT JOIN pg_stat_user_indexes ui1 ON ui1.indexrelid = i1.indexrelid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND i1.indpred IS NULL AND i2.indpred IS NULL
  AND i1.indexprs IS NULL AND i2.indexprs IS NULL
  AND i1.indisvalid AND i2.indisvalid
  AND NOT i1.indisunique
  AND NOT i1.indisreplident
  AND NOT i1.indisclustered
  AND NOT EXISTS (SELECT 1 FROM pg_constraint cc WHERE cc.conindid = i1.indexrelid)
  AND i1.indnatts = i1.indnkeyatts
  AND i2.indnkeyatts >= i1.indnkeyatts
  AND (i2.indkey::smallint[])[0:i1.indnkeyatts - 1]
    = (i1.indkey::smallint[])[0:i1.indnkeyatts - 1]
  AND (i2.indclass::oid[])[0:i1.indnkeyatts - 1]
    = (i1.indclass::oid[])[0:i1.indnkeyatts - 1]
  AND (i2.indcollation::oid[])[0:i1.indnkeyatts - 1]
    = (i1.indcollation::oid[])[0:i1.indnkeyatts - 1]
  AND (i2.indoption::smallint[])[0:i1.indnkeyatts - 1]
    = (i1.indoption::smallint[])[0:i1.indnkeyatts - 1]
  AND (i1.indnkeyatts < i2.indnkeyatts
       OR i2.indnatts > i2.indnkeyatts
       OR i2.indisunique
       OR EXISTS (SELECT 1 FROM pg_constraint cc2 WHERE cc2.conindid = i2.indexrelid)
       OR i1.indexrelid > i2.indexrelid);

\echo '-- rule:unique-extension-index'
INSERT INTO sugg
SELECT
  'CLEANUP', 'LOW', 'Index extends a unique key (trailing columns cannot narrow further)',
  NULL,
  n.nspname || '.' || t.relname,
  'DROP INDEX CONCURRENTLY ' || quote_ident(n.nspname) || '.' || quote_ident(ci1.relname) || ';',
  'leading ' || i2.indnkeyatts || ' column(s) of ' || ci1.relname || ' equal the key set of unique index ' || ci2.relname,
  'extension=' || pg_get_indexdef(i1.indexrelid) || ' || unique=' || pg_get_indexdef(i2.indexrelid)
    || ' size=' || pg_size_pretty(pg_relation_size(i1.indexrelid))
    || ' scans=' || coalesce(ui1.idx_scan, 0),
  'verify no query relies on an index-only scan over the trailing columns, then DROP INDEX CONCURRENTLY; never urgent',
  55
FROM pg_index i1
JOIN pg_index i2 ON i2.indrelid = i1.indrelid AND i2.indexrelid <> i1.indexrelid
JOIN pg_class ci1 ON ci1.oid = i1.indexrelid
JOIN pg_class ci2 ON ci2.oid = i2.indexrelid
JOIN pg_class t ON t.oid = i1.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
LEFT JOIN pg_stat_user_indexes ui1 ON ui1.indexrelid = i1.indexrelid
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND i2.indisunique
  AND NOT i1.indisunique
  AND i1.indisvalid AND i2.indisvalid
  AND i1.indpred IS NULL AND i2.indpred IS NULL
  AND i1.indexprs IS NULL AND i2.indexprs IS NULL
  AND NOT i1.indisreplident
  AND NOT i1.indisclustered
  AND NOT EXISTS (SELECT 1 FROM pg_constraint cc WHERE cc.conindid = i1.indexrelid)
  AND i1.indnkeyatts > i2.indnkeyatts
  AND (i1.indkey::smallint[])[0:i2.indnkeyatts - 1] @> (i2.indkey::smallint[])[0:i2.indnkeyatts - 1]
  AND (i2.indkey::smallint[])[0:i2.indnkeyatts - 1] @> (i1.indkey::smallint[])[0:i2.indnkeyatts - 1];

\echo '-- rule:unused-index'
INSERT INTO sugg
SELECT 'CLEANUP', 'LOW', 'Unused index (no recorded scans)',
  NULL, u.objname, u.ddl, u.detail, u.evidence,
  'confirm the stats window covers periodic jobs (monthly reports etc.), then DROP INDEX CONCURRENTLY; never urgent',
  60
FROM (
  SELECT
    s.schemaname || '.' || s.relname AS objname,
    'DROP INDEX CONCURRENTLY ' || quote_ident(s.schemaname) || '.' || quote_ident(s.indexrelname) || ';' AS ddl,
    CASE WHEN now() - sf.floor_ts < interval '14 days'
         THEN 'STATS WINDOW < 14 DAYS — zero-scan evidence is weak; do not act on it yet'
         ELSE NULL END AS detail,
    'def=' || pg_get_indexdef(i.indexrelid)
      || ' size=' || pg_size_pretty(pg_relation_size(s.indexrelid))
      || ' stats_since=' || sf.floor_ts::date
      || ' (' || extract(day FROM now() - sf.floor_ts)::int || ' days)' AS evidence,
    pg_relation_size(s.indexrelid) AS sz
  FROM pg_stat_user_indexes s
  JOIN pg_index i ON i.indexrelid = s.indexrelid
  CROSS JOIN LATERAL (
    SELECT coalesce(
      (SELECT sd.stats_reset FROM pg_stat_database sd WHERE sd.datname = current_database()),
      (SELECT min(io.stats_reset) FROM pg_stat_io),
      now()) AS floor_ts
  ) sf
  WHERE s.idx_scan = 0
    AND i.indisvalid
    AND NOT i.indisprimary
    AND NOT i.indisunique
    AND NOT i.indisexclusion
    AND NOT i.indisreplident
    AND NOT i.indisclustered
    AND NOT EXISTS (SELECT 1 FROM pg_constraint cc WHERE cc.conindid = i.indexrelid)
    AND pg_relation_size(s.indexrelid) > 128 * 1024
  ORDER BY pg_relation_size(s.indexrelid) DESC
  LIMIT 40
) u;

\echo '-- rule:disabled-trigger'
INSERT INTO sugg
SELECT
  'CLEANUP', 'MEDIUM', 'Disabled trigger still in schema',
  NULL,
  n.nspname || '.' || c.relname,
  'DROP TRIGGER ' || quote_ident(t.tgname) || ' ON '
    || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ';',
  NULL,
  'def=' || pg_get_triggerdef(t.oid),
  'confirm it was not disabled temporarily (migration, bulk load), then drop',
  70
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND t.tgenabled = 'D';

\echo '-- rule:duplicate-triggers'
INSERT INTO sugg
SELECT
  'CLEANUP', 'MEDIUM', 'Duplicate triggers',
  NULL,
  n.nspname || '.' || c.relname,
  NULL,
  'triggers: ' || string_agg(t.tgname, ', ' ORDER BY t.tgname),
  'function=' || p.proname || ' tgtype=' || t.tgtype,
  'inspect pg_get_triggerdef for each; drop one with DROP TRIGGER after verifying',
  75
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE NOT t.tgisinternal
GROUP BY n.nspname, c.relname, p.proname, t.tgrelid, t.tgfoid, t.tgtype,
         t.tgattr::smallint[], pg_get_expr(t.tgqual, t.tgrelid), t.tgargs
HAVING count(*) > 1;

\echo '-- rule:trigger-no-writes'
INSERT INTO sugg
SELECT
  'CLEANUP', 'LOW', 'Trigger on table with no writes',
  NULL,
  st.schemaname || '.' || st.relname || ' (' || t.tgname || ')',
  NULL, NULL,
  'writes=0 since stats reset; def=' || pg_get_triggerdef(t.oid),
  'confirm the table is truly unused before any schema cleanup',
  80
FROM pg_trigger t
JOIN pg_stat_user_tables st ON st.relid = t.tgrelid
WHERE NOT t.tgisinternal
  AND st.n_tup_ins + st.n_tup_upd + st.n_tup_del = 0;
RULES_CLEANUP_SQL
}