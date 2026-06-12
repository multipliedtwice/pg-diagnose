#!/usr/bin/env bash

emit_sugg_rules_plan() {
  cat <<RULES_PLAN_SQL
\echo '-- rule:ann-missing-index'
INSERT INTO sugg
SELECT
  'HIGH',
  CASE WHEN x.param_target THEN 'HIGH' ELSE 'LOW' END,
  'Missing ANN index (vector distance sort)',
  x.top_queryid,
  x.schemaname || '.' || x.relname,
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
    || quote_ident(pg_temp.idx_name(x.relname || '_' || x.colname || '_hnsw_idx'))
    || ' ON ' || quote_ident(x.schemaname) || '.' || quote_ident(x.relname)
    || ' USING hnsw (' || quote_ident(x.colname) || ' ' || o.opclass || ');',
  CASE WHEN x.param_target THEN NULL
       ELSE 'pairwise distance between two columns — no index serves a global sort over pairwise distances; restructure as a LATERAL nested loop (per outer row: ORDER BY inner.'
         || quote_ident(x.colname) || ' ' || x.op || ' outer.' || quote_ident(x.colname)
         || ' LIMIT k) so the index can serve the inner scan' END,
  'queries=' || x.queries || ' queryids=[' || x.queryids || ']'
    || ' combined_total_ms=' || x.total_ms
    || ' pgvector=' || coalesce((SELECT extversion FROM pg_extension WHERE extname = 'vector'), 'not installed')
    || ' target=' || CASE WHEN x.param_target THEN 'parameter/constant' ELSE 'column (pairwise)' END
    || ' sort_expr: ' || left(x.expr, 160),
  '$0 --deep-queryid=' || x.top_queryid,
  8
FROM (
  SELECT z.schemaname, z.relname, z.colname, z.op,
    count(*) AS queries,
    sum(z.total_exec_time)::bigint AS total_ms,
    (array_agg(z.queryid ORDER BY z.total_exec_time DESC))[1] AS top_queryid,
    string_agg(z.queryid::text, ', ' ORDER BY z.total_exec_time DESC) AS queryids,
    max(z.expr) AS expr,
    bool_or(z.param_target) AS param_target
  FROM (
    SELECT DISTINCT ON (y.schemaname, y.relname, y.colname, y.op, y.queryid)
      y.schemaname, y.relname, y.colname, y.op, y.queryid, y.total_exec_time, y.expr, y.param_target
    FROM (
      WITH lim AS (
        SELECT DISTINCT queryid FROM sg_nodes WHERE node ->> 'Node Type' = 'Limit'
      ),
      dsorts AS (
        SELECT n.queryid, n.total_exec_time, n.node -> 'Sort Key' ->> 0 AS sk0
        FROM sg_nodes n
        JOIN lim USING (queryid)
        WHERE n.node ->> 'Node Type' IN ('Sort', 'Incremental Sort')
          AND n.node -> 'Sort Key' ->> 0 ~ '(<->|<=>|<#>|<\+>)'
          AND NOT EXISTS (SELECT 1 FROM sg_rootagg ra WHERE ra.queryid = n.queryid)
      ),
      rels AS (
        SELECT DISTINCT n.queryid,
          coalesce(n.node ->> 'Schema', 'public') AS schemaname,
          n.node ->> 'Relation Name' AS relname,
          coalesce(n.node ->> 'Alias', n.node ->> 'Relation Name') AS als
        FROM sg_nodes n
        WHERE n.node ? 'Relation Name'
      )
      SELECT d.queryid, d.total_exec_time, r.schemaname, r.relname, d.sk0 AS expr,
        k.m[1] AS colname, k.m[2] AS op,
        (d.sk0 ~ '(<->|<=>|<#>|<\+>)[[:space:]]*\(*([\$][0-9]+|'')') AS param_target
      FROM dsorts d
      JOIN rels r USING (queryid)
      CROSS JOIN LATERAL (
        SELECT coalesce(
          regexp_match(d.sk0,
            '(?:\m' || r.als || '\.|"' || r.als || '"\.)"?([A-Za-z_][A-Za-z0-9_]*)"?[[:space:]]*(<->|<=>|<#>|<\+>)'),
          CASE WHEN d.sk0 !~ '\.' THEN regexp_match(d.sk0,
            '(?<![."A-Za-z0-9_])"?([A-Za-z_][A-Za-z0-9_]*)"?[[:space:]]*(<->|<=>|<#>|<\+>)') END
        ) AS m
      ) k
      WHERE k.m IS NOT NULL
    ) y
    ORDER BY y.schemaname, y.relname, y.colname, y.op, y.queryid
  ) z
  GROUP BY z.schemaname, z.relname, z.colname, z.op
) x
JOIN pg_namespace ns3 ON ns3.nspname = x.schemaname
JOIN pg_class c3 ON c3.relnamespace = ns3.oid AND c3.relname = x.relname
JOIN pg_attribute a7 ON a7.attrelid = c3.oid AND a7.attname = x.colname AND NOT a7.attisdropped
JOIN pg_type ty2 ON ty2.oid = a7.atttypid AND ty2.typname IN ('vector', 'halfvec', 'sparsevec')
CROSS JOIN LATERAL (
  SELECT ty2.typname || CASE x.op
    WHEN '<->' THEN '_l2_ops'
    WHEN '<=>' THEN '_cosine_ops'
    WHEN '<#>' THEN '_ip_ops'
    ELSE '_l1_ops'
  END AS opclass
) o
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_index i
  JOIN pg_class ic ON ic.oid = i.indexrelid
  JOIN pg_am am ON am.oid = ic.relam AND am.amname IN ('hnsw', 'ivfflat')
  JOIN pg_opclass oc ON oc.oid = (i.indclass::oid[])[0]
  WHERE i.indrelid = c3.oid
    AND i.indisvalid
    AND (i.indkey::smallint[])[0] = a7.attnum
    AND oc.opcname = o.opclass
);

\echo '-- rule:gin-missing-index'
INSERT INTO sugg
SELECT
  'HIGH', 'HIGH',
  'Missing GIN index (JSONB/array filter)',
  x.top_queryid,
  x.schemaname || '.' || x.relname || '.' || x.colname,
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
    || quote_ident(pg_temp.idx_name(x.relname || '_' || x.colname || '_gin_idx'))
    || ' ON ' || quote_ident(x.schemaname) || '.' || quote_ident(x.relname)
    || ' USING gin (' || quote_ident(x.colname) || ');',
  'type=' || ty.typname || '; serves ' || x.queries || ' distinct statement(s)'
    || CASE WHEN ty.typname = 'jsonb'
            THEN '; if the workload is exclusively @>, USING gin (' || quote_ident(x.colname)
              || ' jsonb_path_ops) is smaller and faster'
            ELSE '' END,
  'queries=' || x.queries || ' queryids=[' || x.queryids || ']'
    || ' combined_total_ms=' || x.total_ms || ' combined_calls=' || x.calls
    || ' predicate: ' || left(x.pred, 160),
  '$0 --deep-queryid=' || x.top_queryid,
  10
FROM sg_container x
JOIN pg_namespace ns ON ns.nspname = x.schemaname
JOIN pg_class c ON c.relnamespace = ns.oid AND c.relname = x.relname
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = x.colname AND NOT a.attisdropped
JOIN pg_type ty ON ty.oid = a.atttypid
WHERE (ty.typcategory = 'A' OR ty.typname = 'jsonb')
  AND pg_relation_size(c.oid) > 10 * 1024 * 1024
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_am am ON am.oid = ic.relam AND am.amname = 'gin'
    WHERE i.indrelid = c.oid
      AND i.indisvalid
      AND i.indkey::smallint[] @> ARRAY[a.attnum]
      AND (i.indpred IS NULL
           OR pg_temp.conjunct_set(pg_get_expr(i.indpred, i.indrelid)) <@ pg_temp.conjunct_set(x.pred))
  );

\echo '-- rule:container-index-unused'
INSERT INTO sugg
SELECT
  'HIGH', 'MEDIUM',
  'Existing GIN index not chosen by the planner',
  x.top_queryid,
  x.schemaname || '.' || x.relname || ' (' || g.idxname || ')',
  NULL,
  'column=' || x.colname || '; if statistics are the cause: ANALYZE '
    || quote_ident(x.schemaname) || '.' || quote_ident(x.relname)
    || ' and consider ALTER TABLE ... ALTER COLUMN ' || quote_ident(x.colname) || ' SET STATISTICS 1000',
  'index=' || g.idxname || ' idx_scan=' || g.scans
    || ' combined_calls=' || x.calls || ' combined_total_ms=' || x.total_ms
    || ' mean_ms=' || (x.total_ms / greatest(x.calls, 1))
    || ' queryids=[' || x.queryids || '] predicate: ' || left(x.pred, 160),
  '$0 --deep-queryid=' || x.top_queryid,
  12
FROM sg_container x
JOIN pg_namespace ns ON ns.nspname = x.schemaname
JOIN pg_class c ON c.relnamespace = ns.oid AND c.relname = x.relname
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = x.colname AND NOT a.attisdropped
JOIN pg_type ty ON ty.oid = a.atttypid
JOIN LATERAL (
  SELECT ic.relname AS idxname, coalesce(ui.idx_scan, 0) AS scans
  FROM pg_index i
  JOIN pg_class ic ON ic.oid = i.indexrelid
  JOIN pg_am am ON am.oid = ic.relam AND am.amname = 'gin'
  LEFT JOIN pg_stat_user_indexes ui ON ui.indexrelid = i.indexrelid
  WHERE i.indrelid = c.oid
    AND i.indisvalid
    AND i.indkey::smallint[] @> ARRAY[a.attnum]
  ORDER BY coalesce(ui.idx_scan, 0) DESC
  LIMIT 1
) g ON TRUE
WHERE (ty.typcategory = 'A' OR ty.typname = 'jsonb')
  AND x.total_ms / greatest(x.calls, 1) > 1000
  AND g.scans * 2 < x.calls;

\echo '-- rule:trgm-missing-index'
INSERT INTO sugg
SELECT
  'MEDIUM',
  CASE WHEN position(' OR ' in x.pred) > 0 THEN 'LOW' ELSE 'MEDIUM' END,
  'Missing trigram index (pattern-match filter)',
  x.top_queryid,
  x.schemaname || '.' || x.relname || '.' || x.colname,
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
    || quote_ident(pg_temp.idx_name(x.relname || '_' || x.colname || '_trgm_idx'))
    || ' ON ' || quote_ident(x.schemaname) || '.' || quote_ident(x.relname)
    || ' USING gin (' || quote_ident(x.colname) || ' gin_trgm_ops);',
  CASE WHEN position(' OR ' in x.pred) > 0
       THEN 'the pattern sits inside an OR — one index alone cannot serve it; Postgres can BitmapOr several trgm indexes, so consider the full set of pattern columns or restructure'
       ELSE NULL END,
  'queries=' || x.queries || ' queryids=[' || x.queryids || ']'
    || ' combined_total_ms=' || x.total_ms || ' combined_calls=' || x.calls
    || ' predicate: ' || left(x.pred, 160),
  '$0 --deep-queryid=' || x.top_queryid,
  15
FROM sg_like x
JOIN pg_namespace ns ON ns.nspname = x.schemaname
JOIN pg_class c ON c.relnamespace = ns.oid AND c.relname = x.relname
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = x.colname AND NOT a.attisdropped
JOIN pg_type ty ON ty.oid = a.atttypid AND ty.typcategory = 'S'
WHERE EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')
  AND pg_relation_size(c.oid) > 10 * 1024 * 1024
  AND x.total_ms / greatest(x.calls, 1) > 500
  AND NOT EXISTS (
    SELECT 1
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_am am ON am.oid = ic.relam AND am.amname IN ('gin', 'gist')
    WHERE i.indrelid = c.oid
      AND i.indisvalid
      AND array_position(i.indkey::smallint[], a.attnum) IS NOT NULL
      AND (SELECT oc.opcname FROM pg_opclass oc
           WHERE oc.oid = (i.indclass::oid[])[array_position(i.indkey::smallint[], a.attnum)])
          IN ('gin_trgm_ops', 'gist_trgm_ops')
  );

\echo '-- rule:plan-runtime-mismatch'
INSERT INTO sugg
SELECT
  CASE WHEN p.total_exec_time > 0.05 * w.total_ms THEN 'HIGH' ELSE 'MEDIUM' END,
  'MEDIUM',
  'Cheap plan but high observed runtime',
  p.queryid,
  NULL,
  NULL,
  CASE WHEN current_setting('track_io_timing') = 'off'
       THEN 'track_io_timing=off — enable it (see config phase) so the next run can attribute this to I/O vs CPU'
       ELSE NULL END,
  'queryid=' || p.queryid || ' calls=' || p.calls
    || ' mean_ms=' || p.mean_exec_time::int
    || ' total_ms=' || p.total_exec_time::int
    || ' workload_share=' || round((100.0 * p.total_exec_time / NULLIF(w.total_ms, 0))::numeric, 1) || '%'
    || ' plan_total_cost=' || pc.cost::int
    || ' toast_blks_read(referenced tables)=' || coalesce(tt.toast_read::text, '0'),
  '$0 --deep-queryid=' || p.queryid,
  14
FROM sg_plans p
CROSS JOIN sg_workload w
CROSS JOIN LATERAL (
  SELECT (p.plan -> 0 -> 'Plan' ->> 'Total Cost')::numeric AS cost
) pc
LEFT JOIN LATERAL (
  SELECT sum(st.toast_blks_read) AS toast_read
  FROM (
    SELECT DISTINCT coalesce(n.node ->> 'Schema', 'public') AS sn,
           n.node ->> 'Relation Name' AS rn
    FROM sg_nodes n
    WHERE n.queryid = p.queryid AND n.node ? 'Relation Name'
  ) r
  JOIN pg_statio_user_tables st ON st.schemaname = r.sn AND st.relname = r.rn
) tt ON TRUE
WHERE p.planmode IN ('generic', 'generic-rewritten')
  AND p.plan IS NOT NULL
  AND pc.cost IS NOT NULL
  AND pc.cost < 2000
  AND p.calls > 100
  AND p.total_exec_time > 60000
  AND p.mean_exec_time > greatest(20, pc.cost * 0.5);

\echo '-- rule:sorted-pagination'
INSERT INTO sugg
SELECT
  CASE WHEN raw.total_exec_time > 0.02 * w.total_ms THEN 'HIGH' ELSE 'MEDIUM' END,
  CASE WHEN srv.idxname IS NOT NULL THEN 'LOW'
       WHEN raw.param_free THEN 'MEDIUM'
       WHEN ec.eq_cols IS NOT NULL THEN 'MEDIUM'
       ELSE 'LOW' END,
  CASE WHEN srv.idxname IS NOT NULL
       THEN 'Ordered index exists but planner not choosing it (sorted pagination)'
       ELSE 'Missing index for sorted pagination' END,
  raw.queryid,
  raw.fqname,
  CASE WHEN srv.idxname IS NOT NULL THEN NULL
       ELSE 'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
    || quote_ident(pg_temp.idx_name(raw.relname || '_' || raw.sortcol || '_order_idx'))
    || ' ON ' || raw.fqname_q
    || ' ('
    || CASE WHEN NOT raw.param_free AND ec.eq_cols IS NOT NULL
            THEN ec.eq_cols || ', ' ELSE '' END
    || quote_ident(raw.sortcol) || ' ' || raw.dir
    || coalesce(' ' || raw.nulls_opt, '')
    || CASE WHEN s.pkcol IS NOT NULL AND s.pkcol <> raw.sortcol
            THEN ', ' || quote_ident(s.pkcol) || ' ' || raw.dir ELSE '' END
    || ')'
    || CASE WHEN raw.param_free THEN ' WHERE ' || raw.pred_clean ELSE '' END
    || ';' END,
  CASE WHEN srv.idxname IS NOT NULL
       THEN 'existing index ' || srv.idxname || ' (idx_scan=' || srv.scans
         || ') already provides this order for this predicate — investigate why the plan sorts instead'
       WHEN NOT raw.param_free AND fl.has_or
       THEN 'predicate contains OR — equality-prefix shapes do not apply; consider a UNION rewrite or per-branch partial indexes'
       WHEN NOT raw.param_free AND ec.eq_cols IS NOT NULL
       THEN 'parameterized predicate — the DDL is a SHAPE (equality/IS NULL columns first, then the sort column), not ready-to-run SQL; confirm the equality set matches all callers'
       WHEN NOT raw.param_free
       THEN 'parameterized predicate with no equality columns detected — suggested index is unpartial and may be large; verify first'
       ELSE NULL END,
  'queryid=' || raw.queryid || ' calls=' || raw.calls || ' total_ms=' || raw.total_exec_time::int
    || ' workload_share=' || round((100.0 * raw.total_exec_time / NULLIF(w.total_ms, 0))::numeric, 1) || '%'
    || ' mean_ms=' || raw.mean_exec_time::int || ' sort_key=' || raw.sk0
    || coalesce(' eq_cols=' || ec.eq_cols, '')
    || ' scan_predicate: ' || left(raw.pred_clean, 160),
  '$0 --deep-queryid=' || raw.queryid,
  20
FROM (
  WITH lim AS (
    SELECT DISTINCT queryid FROM sg_nodes
    WHERE node ->> 'Node Type' = 'Limit'
      AND planmode IN ('generic', 'generic-rewritten')
      AND NOT EXISTS (SELECT 1 FROM sg_rootagg ra WHERE ra.queryid = sg_nodes.queryid)
  ),
  sorts AS (
    SELECT n.queryid,
      n.node -> 'Sort Key' ->> 0 AS sk0,
      jsonb_array_length(n.node -> 'Sort Key') AS skn
    FROM sg_nodes n
    JOIN lim USING (queryid)
    WHERE n.node ->> 'Node Type' IN ('Sort', 'Incremental Sort')
      AND n.planmode IN ('generic', 'generic-rewritten')
  ),
  scans AS (
    SELECT n.queryid,
      coalesce(n.node ->> 'Schema', 'public') AS schemaname,
      n.node ->> 'Relation Name' AS relname,
      coalesce(n.node ->> 'Alias', n.node ->> 'Relation Name') AS als,
      n.node ->> 'Node Type' AS scan_type,
      concat_ws(' AND ',
        n.node ->> 'Index Cond',
        n.node ->> 'Recheck Cond',
        n.node ->> 'Filter') AS full_pred,
      count(*) OVER (PARTITION BY n.queryid) AS scan_cnt
    FROM sg_nodes n
    JOIN lim USING (queryid)
    WHERE n.node ->> 'Node Type' IN ('Seq Scan', 'Bitmap Heap Scan')
      AND (n.node ? 'Filter' OR n.node ? 'Recheck Cond')
      AND n.planmode IN ('generic', 'generic-rewritten')
  )
  SELECT t.queryid, t.calls, t.total_exec_time, t.mean_exec_time,
    so.sk0,
    sc.scan_type,
    sc.schemaname,
    sc.relname,
    sc.schemaname || '.' || sc.relname AS fqname,
    quote_ident(sc.schemaname) || '.' || quote_ident(sc.relname) AS fqname_q,
    trim(both '"' from (sk.m)[1]) AS sortcol,
    coalesce((sk.m)[2], 'ASC') AS dir,
    (sk.m)[3] AS nulls_opt,
    (sc.full_pred !~ '[\$][0-9]') AS param_free,
    regexp_replace(
      regexp_replace(sc.full_pred, '"' || sc.als || '"\.', '', 'g'),
      '\m' || sc.als || '\.', '', 'g'
    ) AS pred_clean
  FROM sorts so
  JOIN scans sc ON sc.queryid = so.queryid AND sc.scan_cnt = 1
  JOIN sg_top t ON t.queryid = so.queryid
  CROSS JOIN LATERAL (
    SELECT regexp_match(
      regexp_replace(so.sk0, '^"?[^".]*"?\.', ''),
      '^("[^"]+"|[A-Za-z_][A-Za-z0-9_]*)[[:space:]]*(DESC|ASC)?[[:space:]]*(NULLS[[:space:]]+(?:FIRST|LAST))?[[:space:]]*\$'
    ) AS m
  ) sk
  WHERE so.skn = 1
    AND sk.m IS NOT NULL
    AND (so.sk0 LIKE sc.als || '.%'
         OR so.sk0 LIKE '"' || sc.als || '".%'
         OR so.sk0 NOT LIKE '%.%')
) raw
CROSS JOIN sg_workload w
CROSS JOIN LATERAL (
  SELECT position(' OR ' in raw.pred_clean) > 0 AS has_or
) fl
JOIN pg_namespace ns2 ON ns2.nspname = raw.schemaname
JOIN pg_class c2 ON c2.relnamespace = ns2.oid AND c2.relname = raw.relname
JOIN pg_attribute a3 ON a3.attrelid = c2.oid AND a3.attname = raw.sortcol AND NOT a3.attisdropped
CROSS JOIN LATERAL (
  SELECT
    (SELECT a5.attname
       FROM pg_index pi
       JOIN pg_attribute a5 ON a5.attrelid = pi.indrelid
        AND a5.attnum = (pi.indkey::smallint[])[0]
       WHERE pi.indrelid = c2.oid AND pi.indisprimary
       LIMIT 1) AS pkcol
) s
CROSS JOIN LATERAL (
  SELECT string_agg(quote_ident(qq.col), ', ') AS eq_cols,
         array_agg(ae.attnum) AS eq_attnums
  FROM (
    SELECT DISTINCT m2[1] AS col
    FROM regexp_matches(raw.pred_clean,
      '"?([A-Za-z_][A-Za-z0-9_]*)"?\)?(?:::[A-Za-z_ ]+(\[\])?)?[[:space:]]*=[[:space:]]*(?:ANY[[:space:]]*\()?\(?[\$][0-9]+',
      'g') AS m2
    UNION
    SELECT DISTINCT m3[1] AS col
    FROM regexp_matches(raw.pred_clean,
      '"?([A-Za-z_][A-Za-z0-9_]*)"?[[:space:]]+IS[[:space:]]+NULL',
      'g') AS m3
  ) qq
  JOIN pg_attribute ae ON ae.attrelid = c2.oid
    AND ae.attname = qq.col
    AND NOT ae.attisdropped
    AND ae.attnum > 0
  WHERE qq.col <> raw.sortcol
    AND NOT fl.has_or
) ec
LEFT JOIN LATERAL (
  SELECT ci.relname AS idxname, coalesce(ui.idx_scan, 0) AS scans
  FROM pg_index i2
  JOIN pg_class ci ON ci.oid = i2.indexrelid
  LEFT JOIN pg_stat_user_indexes ui ON ui.indexrelid = i2.indexrelid
  CROSS JOIN LATERAL (
    SELECT array_position(i2.indkey::smallint[], a3.attnum) AS sp
  ) k
  WHERE i2.indrelid = c2.oid
    AND i2.indisvalid
    AND k.sp IS NOT NULL
    AND k.sp < i2.indnkeyatts
    AND (i2.indkey::smallint[])[0:k.sp - 1] <@ coalesce(ec.eq_attnums, '{}'::smallint[])
    AND (i2.indpred IS NULL
         OR pg_temp.conjunct_set(pg_get_expr(i2.indpred, i2.indrelid)) <@ pg_temp.conjunct_set(raw.pred_clean))
  ORDER BY (i2.indpred IS NOT NULL) DESC, k.sp, ci.relname
  LIMIT 1
) srv ON TRUE
WHERE pg_relation_size(c2.oid) > 10 * 1024 * 1024;

\echo '-- rule:disk-spill'
INSERT INTO sugg
SELECT
  'MEDIUM', 'MEDIUM', 'Query spills to disk during sort/hash',
  t.queryid, NULL, NULL, NULL,
  'queryid=' || t.queryid || ' calls=' || t.calls
    || ' temp_written=' || pg_size_pretty((t.temp_blks_written * 8192)::bigint)
    || ' total_ms=' || t.total_exec_time::int,
  '$0 --deep-queryid=' || t.queryid,
  40
FROM (
  SELECT s.queryid, s.calls, s.total_exec_time, s.temp_blks_written
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  WHERE s.temp_blks_written > 5000
    AND ${PGSS_FILTER}
  ORDER BY s.temp_blks_written DESC
  LIMIT 5
) t;

\echo '-- rule:repeated-expensive-aggregate'
INSERT INTO sugg
SELECT
  'MEDIUM', 'MEDIUM', 'Repeated expensive aggregate — cache or materialize',
  t.queryid, NULL, NULL, NULL,
  'queryid=' || t.queryid || ' calls=' || t.calls
    || ' mean_ms=' || t.mean_exec_time::int
    || ' total_ms=' || t.total_exec_time::int
    || ' rows_per_call=' || (t.rows / greatest(t.calls, 1)),
  '$0 --deep-queryid=' || t.queryid,
  22
FROM (
  SELECT s.queryid, s.calls, s.mean_exec_time, s.total_exec_time, s.rows
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
  WHERE s.calls > 10
    AND s.mean_exec_time > 5000
    AND s.rows / greatest(s.calls, 1) < 100
    AND s.query ~* '(group[[:space:]]+by|count[[:space:]]*\()'
    AND ${PGSS_FILTER}
    AND (NOT EXISTS (SELECT 1 FROM sg_plans p WHERE p.queryid = s.queryid AND p.plan IS NOT NULL)
         OR EXISTS (SELECT 1 FROM sg_rootagg ra WHERE ra.queryid = s.queryid))
  ORDER BY s.total_exec_time DESC
  LIMIT 5
) t;
RULES_PLAN_SQL
}