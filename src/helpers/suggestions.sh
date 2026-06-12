#!/usr/bin/env bash

suggestions_mode() {
  local CLEANUP_PRED="severity <> 'CLEANUP'"
  local SUGG_OUT SUGG_RC ERR_COUNT DBNAME STATS_DAYS SQL_LABEL
  if [[ "$INCLUDE_CLEANUP" == "1" ]]; then
    CLEANUP_PRED="TRUE"
  fi

  SQL_LABEL="suggested SQL"
  if [[ "$PRISMA_OUT" == "1" ]]; then
    SQL_LABEL="suggested change (Prisma / SQL)"
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
  echo
  echo "   next_action tiers:"
  echo "     TEST FIRST       = high confidence — ready to test on a staging copy"
  echo "     VERIFY FIRST     = plausible — verify the query plan before applying"
  echo "     INVESTIGATE ONLY = weak evidence — candidate SQL hidden by default"
  echo "                        (rerun with --show-low-confidence-sql to see it)"
  echo "     OPTIONAL CLEANUP = housekeeping — never urgent, not a performance fix"
  if [[ "$INCLUDE_CLEANUP" != "1" ]]; then
    echo "   (OPTIONAL CLEANUP suggestions are hidden — add --include-cleanup to show)"
  fi
  echo "   (evidence here is lifetime pg_stat_statements + catalogs;"
  echo "    window-level evidence requires a full run)"
  echo "   (active, enabled triggers are never judged droppable from statistics —"
  echo "    only disabled, duplicate, and never-firing triggers are flagged)"
  echo "   (coverage limit: this mode only detects specific plan shapes —"
  echo "    GIN-able filters, vector-distance sorts, sorted pagination, disk spills —"
  echo "    plus catalog facts: stale statistics, dead tuples, unindexed foreign keys."
  echo "    A plain missing btree index (WHERE col = \$1 running as a Seq Scan)"
  echo "    is NOT auto-suggested: generic plans make it false-positive-prone."
  echo "    For those, start from the full run's 'heavy seq scans' section and"
  echo "    investigate manually: $0 --deep-queryid=<queryid>)"
  if [[ "$PRISMA_OUT" == "1" ]]; then
    echo "   prisma output:"
    echo "     - model and field names are emitted as raw table/column names —"
    echo "       adjust manually where your schema uses @@map / @map"
    echo "     - partial indexes require previewFeatures = [\"partialIndexes\"]"
    echo "       (Prisma >= 7.4, preview — known migrate-dev drift bugs; verify"
    echo "       prisma migrate dev stays in sync before adopting)"
    echo "     - Prisma cannot create indexes CONCURRENTLY — the raw SQL stays"
    echo "       attached to each index suggestion for large live tables"
    echo "     - ANN indexes (hnsw/ivfflat) are not expressible in Prisma schema —"
    echo "       they stay raw SQL (deliver via an edited migration file)"
    echo "     - ANALYZE/VACUUM suggestions stay SQL (they are not schema changes)"
  fi
  echo "   (if any SQL error occurs, all suggestions from the run are suppressed —"
  echo "    rerun with --debug to inspect the raw partial output)"
  if [[ "$STATS_DAYS" =~ ^[0-9]+$ && "$STATS_DAYS" -lt 14 ]]; then
    echo "   ⚠  statistics cover only ${STATS_DAYS} day(s) — usage-based evidence is weak"
  fi

  if [[ "$HAS_PGSS" != "t" ]]; then
    echo "   ⚠  pg_stat_statements not usable: query-based rules skipped; catalog rules still run."
  fi

  set +e
  SUGG_OUT="$(psql_run_tolerant 2>&1 <<SUGG_SQL
SET statement_timeout = '120s';
SET lock_timeout = '2s';

SELECT /* pg-diagnose */ '${HAS_PGSS}' = 't' AS has_pgss \gset

CREATE TEMP TABLE sugg (
  severity text,
  confidence text,
  category text,
  queryid bigint,
  objname text,
  suggested_sql text,
  reason text,
  evidence text,
  verify_cmd text,
  risk text,
  do_not_apply_if text,
  sort int
);

CREATE FUNCTION pg_temp.idx_name(base text) RETURNS text
LANGUAGE sql AS \$fn\$
  SELECT CASE WHEN length(base) <= 63 THEN base
              ELSE left(base, 56) || '_' || left(md5(base), 6) END
\$fn\$;

CREATE FUNCTION pg_temp.to_prisma(stmt text) RETURNS text
LANGUAGE plpgsql AS \$fn\$
DECLARE
  m text[];
  cm text[];
  c text;
  attr text;
  parts text[] := '{}';
  notes text[] := '{}';
  body text;
BEGIN
  IF stmt ~* '^\s*(ANALYZE|VACUUM)' THEN
    RETURN trim(stmt) || E'\n// maintenance command — run as SQL; there is no Prisma schema equivalent';
  END IF;
  IF stmt ~* '^\s*DROP\s+INDEX' THEN
    RETURN '// remove the matching @@index / @unique attribute from the model, then run: ' || trim(stmt);
  END IF;
  IF stmt ~* 'USING\s+(hnsw|ivfflat)' THEN
    RETURN '// ANN index — not expressible in Prisma schema; keep as raw SQL (edited migration file): ' || trim(stmt);
  END IF;
  m := regexp_match(stmt,
    '^\s*CREATE\s+INDEX\s+CONCURRENTLY\s+IF\s+NOT\s+EXISTS\s+"?([A-Za-z0-9_]+)"?\s+ON\s+(?:"?[A-Za-z0-9_]+"?\.)?"?([A-Za-z0-9_]+)"?\s+(USING\s+gin\s+)?\(([^)]*)\)\s*(?:WHERE\s+(.+))?;\s*\$',
    'i');
  IF m IS NULL THEN
    RETURN '// not translatable to Prisma schema — keep as raw SQL: ' || trim(stmt);
  END IF;
  FOREACH c IN ARRAY regexp_split_to_array(m[4], '\s*,\s*') LOOP
    cm := regexp_match(c,
      '^"?([A-Za-z0-9_]+)"?(\s+jsonb_path_ops)?(\s+(ASC|DESC))?(\s+NULLS\s+(FIRST|LAST))?\s*\$', 'i');
    IF cm IS NULL THEN
      RETURN '// could not parse the column list — keep as raw SQL: ' || trim(stmt);
    END IF;
    attr := cm[1];
    IF cm[2] IS NOT NULL AND cm[4] IS NOT NULL AND upper(cm[4]) = 'DESC' THEN
      attr := attr || '(ops: JsonbPathOps, sort: Desc)';
    ELSIF cm[2] IS NOT NULL THEN
      attr := attr || '(ops: JsonbPathOps)';
    ELSIF cm[4] IS NOT NULL AND upper(cm[4]) = 'DESC' THEN
      attr := attr || '(sort: Desc)';
    END IF;
    IF cm[6] IS NOT NULL THEN
      notes := notes || ('NULLS ' || upper(cm[6]) || ' on ' || cm[1]
        || ' is not expressible in Prisma and was dropped — verify plan equivalence or keep the raw SQL');
    END IF;
    parts := parts || attr;
  END LOOP;
  IF m[5] IS NOT NULL THEN
    notes := notes || 'partial index: requires previewFeatures = ["partialIndexes"] (Prisma >= 7.4, preview) — known migrate-dev drift bugs; verify migrations stay in sync or keep the raw SQL';
  END IF;
  notes := notes || ('Prisma cannot create indexes CONCURRENTLY — for a large live table run the raw SQL first, then baseline the migration: ' || trim(stmt));
  body := 'model ' || m[2] || ' {'
    || E'\n  @@index([' || array_to_string(parts, ', ') || ']'
    || ', map: "' || m[1] || '"'
    || CASE WHEN m[3] IS NOT NULL THEN ', type: Gin' ELSE '' END
    || CASE WHEN m[5] IS NOT NULL
            THEN ', where: raw("' || replace(replace(m[5], '\', '\\\\'), '"', '\"') || '")'
            ELSE '' END
    || ')' || E'\n}';
  RETURN body || E'\n// ' || array_to_string(notes, E'\n// ');
END
\$fn\$;

CREATE FUNCTION pg_temp.to_prisma_block(ddl text) RETURNS text
LANGUAGE sql AS \$fn\$
  SELECT string_agg(pg_temp.to_prisma(s), E'\n')
  FROM unnest(string_to_array(ddl, E'\n')) AS s
  WHERE length(trim(s)) > 0
\$fn\$;

\if :has_pgss
CREATE FUNCTION pg_temp.explain_generic(q text) RETURNS jsonb
LANGUAGE plpgsql AS \$fn\$
DECLARE r json;
BEGIN
  EXECUTE 'EXPLAIN (GENERIC_PLAN, VERBOSE, FORMAT JSON) ' || q INTO r;
  RETURN r::jsonb;
EXCEPTION WHEN OTHERS THEN
  RETURN NULL;
END
\$fn\$;

CREATE TEMP TABLE sg_top AS
SELECT s.queryid, s.calls, s.total_exec_time, s.mean_exec_time, s.temp_blks_written, s.query
FROM pg_stat_statements s
JOIN pg_database d ON d.oid = s.dbid AND d.datname = current_database()
WHERE s.calls > 5
  AND s.query ~* '^[[:space:]]*(select|with|update|delete|insert)'
  AND ${PGSS_FILTER}
ORDER BY s.total_exec_time DESC
LIMIT 15;

CREATE TEMP TABLE sg_plans AS
SELECT t.queryid, t.calls, t.total_exec_time, t.mean_exec_time, t.query,
       pg_temp.explain_generic(t.query) AS plan
FROM sg_top t;

CREATE TEMP TABLE sg_nodes AS
WITH RECURSIVE nodes (queryid, calls, total_exec_time, mean_exec_time, node) AS (
  SELECT p.queryid, p.calls, p.total_exec_time, p.mean_exec_time, p.plan -> 0 -> 'Plan'
  FROM sg_plans p
  WHERE p.plan IS NOT NULL
  UNION ALL
  SELECT n.queryid, n.calls, n.total_exec_time, n.mean_exec_time, child.value
  FROM nodes n
  CROSS JOIN LATERAL jsonb_array_elements(n.node -> 'Plans') AS child
  WHERE jsonb_typeof(n.node -> 'Plans') = 'array'
)
SELECT * FROM nodes;

\echo
\echo '── generic-plan coverage ──'
SELECT
  count(*) AS top_stmts_checked,
  count(*) FILTER (WHERE plan IS NULL) AS skipped_unplannable
FROM sg_plans;

INSERT INTO sugg
SELECT
  'HIGH', 'HIGH',
  'Missing ANN index (vector distance sort)',
  x.top_queryid,
  x.schemaname || '.' || x.relname,
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
    || quote_ident(pg_temp.idx_name(x.relname || '_' || x.colname || '_hnsw_idx'))
    || ' ON ' || quote_ident(x.schemaname) || '.' || quote_ident(x.relname)
    || ' USING hnsw (' || quote_ident(x.colname) || ' ' || o.opclass || ');',
  'ORDER BY a vector distance over ' || x.colname || ' computes the distance for every candidate row and sorts the full set on every call. An HNSW index serves ORDER BY '
    || quote_ident(x.colname) || ' ' || x.op
    || ' <param> LIMIT n directly. Results become APPROXIMATE (recall vs speed: hnsw.ef_search). The index is used ONLY when the ORDER BY expression is the bare ascending distance — rewrite forms like (constant - (col '
    || x.op || ' v)) DESC to the bare distance and derive similarity in the select list. A partial index (e.g. WHERE "deletedAt" IS NULL AND '
    || quote_ident(x.colname) || ' IS NOT NULL) is smaller, but every query must repeat the predicate verbatim.',
  'queries=' || x.queries || ' queryids=[' || x.queryids || ']'
    || ' combined_total_ms=' || x.total_ms
    || ' pgvector=' || coalesce((SELECT extversion FROM pg_extension WHERE extname = 'vector'), 'not installed')
    || ' sort_expr: ' || left(x.expr, 160),
  '$0 --deep-queryid=' || x.top_queryid,
  'Approximate results; combined with selective filters it can return fewer than LIMIT rows (pgvector >= 0.8: hnsw.iterative_scan). The build is memory/time heavy (maintenance_work_mem) and every write to ' || x.colname || ' updates the graph.',
  'The workload aggregates over all matching rows, exact ordering is required, or the ORDER BY cannot be rewritten to the bare distance expression.',
  8
FROM (
  SELECT z.schemaname, z.relname, z.colname, z.op,
    count(*) AS queries,
    sum(z.total_exec_time)::bigint AS total_ms,
    (array_agg(z.queryid ORDER BY z.total_exec_time DESC))[1] AS top_queryid,
    string_agg(z.queryid::text, ', ' ORDER BY z.total_exec_time DESC) AS queryids,
    max(z.expr) AS expr
  FROM (
    SELECT DISTINCT ON (y.schemaname, y.relname, y.colname, y.op, y.queryid)
      y.schemaname, y.relname, y.colname, y.op, y.queryid, y.total_exec_time, y.expr
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
        k.m[1] AS colname, k.m[2] AS op
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

INSERT INTO sugg
SELECT
  'HIGH', 'HIGH',
  CASE WHEN ty.typname = 'jsonb' THEN 'Missing GIN index (JSONB filter)'
       ELSE 'Missing GIN index (array filter)' END,
  x.top_queryid,
  x.schemaname || '.' || x.relname,
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
    || quote_ident(pg_temp.idx_name(x.relname || '_' || x.colname || '_gin_idx'))
    || ' ON ' || quote_ident(x.schemaname) || '.' || quote_ident(x.relname)
    || ' USING gin (' || quote_ident(x.colname) || ');',
  'A JSONB/array operator (@>, && or <@) on ' || x.colname || ' (' || ty.typname
    || ') is tested row-by-row as a plan Filter: every candidate row is fetched and checked. A GIN index serves these operators directly.'
    || ' This index serves ' || x.queries || ' distinct statement(s).'
    || CASE WHEN ty.typname = 'jsonb'
            THEN ' If the workload is exclusively @>, USING gin (' || quote_ident(x.colname)
              || ' jsonb_path_ops) is smaller and faster.'
            ELSE '' END,
  'queries=' || x.queries || ' queryids=[' || x.queryids || ']'
    || ' combined_total_ms=' || x.total_ms || ' combined_calls=' || x.calls
    || ' predicate: ' || left(x.pred, 160),
  '$0 --deep-queryid=' || x.top_queryid,
  'GIN indexes are larger and slower to update than btree: every write to ' || x.relname || ' must also update the new index.',
  'Queries always pair this column with a selective btree condition that already narrows to few rows. A partial GIN (e.g. WHERE "deletedAt" IS NULL) can shrink it.',
  10
FROM (
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
               coalesce(n.node ->> 'Filter', n.node ->> 'Recheck Cond') AS rawpred
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
  GROUP BY z.schemaname, z.relname, z.colname
) x
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
  );

INSERT INTO sugg
SELECT
  CASE WHEN raw.total_exec_time > 60000 THEN 'HIGH' ELSE 'MEDIUM' END,
  CASE WHEN s.matching_partial_index IS NOT NULL AND raw.param_free THEN 'HIGH'
       WHEN raw.param_free THEN 'MEDIUM'
       WHEN ec.eq_cols IS NOT NULL THEN 'MEDIUM'
       ELSE 'LOW' END,
  'Missing index for sorted pagination',
  raw.queryid,
  raw.fqname,
  'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
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
    || ';',
  'Limit above Sort above ' || raw.scan_type || ': every call scans and sorts the full matching set before pagination. An ordered '
    || CASE WHEN raw.param_free THEN 'partial ' ELSE '' END
    || 'index lets Limit stop early.'
    || CASE WHEN s.matching_partial_index IS NOT NULL
            THEN ' Existing index ' || s.matching_partial_index
              || ' already has this exact predicate but orders by a different column.'
            ELSE '' END
    || CASE WHEN NOT raw.param_free AND fl.has_or
            THEN ' Predicate contains OR — equality-prefix index shapes do not apply; consider a UNION rewrite or per-branch partial indexes.'
            WHEN NOT raw.param_free AND ec.eq_cols IS NOT NULL
            THEN ' Predicate is parameterized — the suggested DDL is a SHAPE (detected equality columns first, then the sort column), not ready-to-run SQL. Confirm the equality set matches all callers before applying.'
            WHEN NOT raw.param_free
            THEN ' Predicate contains parameters and no equality columns were detected — suggested index is unpartial and may be large; verify first.'
            ELSE '' END,
  'queryid=' || raw.queryid || ' calls=' || raw.calls || ' total_ms=' || raw.total_exec_time::int
    || ' mean_ms=' || raw.mean_exec_time::int || ' sort_key=' || raw.sk0
    || coalesce(' eq_cols=' || ec.eq_cols, '')
    || ' scan_predicate: ' || left(raw.pred_clean, 160),
  '$0 --deep-queryid=' || raw.queryid,
  'Every write to ' || raw.fqname || ' must also update the new index. Deep OFFSET stays O(offset) even with the index — keyset pagination is the durable fix.',
  'The ORDER BY column is about to change, the predicate is not stable across callers, or an equivalent index exists that the planner is not choosing (investigate why instead).',
  20
FROM (
  WITH lim AS (
    SELECT DISTINCT queryid FROM sg_nodes WHERE node ->> 'Node Type' = 'Limit'
  ),
  sorts AS (
    SELECT n.queryid,
      n.node -> 'Sort Key' ->> 0 AS sk0,
      jsonb_array_length(n.node -> 'Sort Key') AS skn
    FROM sg_nodes n
    JOIN lim USING (queryid)
    WHERE n.node ->> 'Node Type' IN ('Sort', 'Incremental Sort')
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
  )
  SELECT t.queryid, t.calls, t.total_exec_time, t.mean_exec_time,
    so.sk0,
    sc.scan_type,
    sc.schemaname,
    sc.relname,
    sc.schemaname || '.' || sc.relname AS fqname,
    quote_ident(sc.schemaname) || '.' || quote_ident(sc.relname) AS fqname_q,
    (sk.m)[1] AS sortcol,
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
      '^"?([A-Za-z_][A-Za-z0-9_]*|[^"]+)"?[[:space:]]*(DESC|ASC)?[[:space:]]*(NULLS[[:space:]]+(?:FIRST|LAST))?[[:space:]]*\$'
    ) AS m
  ) sk
  WHERE so.skn = 1
    AND (so.sk0 LIKE sc.als || '.%'
         OR so.sk0 LIKE '"' || sc.als || '".%'
         OR so.sk0 NOT LIKE '%.%')
) raw
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
       LIMIT 1) AS pkcol,
    (SELECT ci.relname
       FROM pg_index i
       JOIN pg_class ci ON ci.oid = i.indexrelid
       WHERE i.indrelid = c2.oid
         AND i.indisvalid
         AND i.indpred IS NOT NULL
         AND replace(pg_get_expr(i.indpred, i.indrelid), ' ', '')
           = replace(raw.pred_clean, ' ', '')
       LIMIT 1) AS matching_partial_index
) s
CROSS JOIN LATERAL (
  SELECT string_agg(quote_ident(qq.col), ', ') AS eq_cols,
         array_agg(ae.attnum) AS eq_attnums,
         count(*)::int AS eq_count
  FROM (
    SELECT DISTINCT m2[1] AS col
    FROM regexp_matches(raw.pred_clean,
      '"?([A-Za-z_][A-Za-z0-9_]*)"?\)?(?:::[A-Za-z_ ]+(\[\])?)?[[:space:]]*=[[:space:]]*(?:ANY[[:space:]]*\()?\(?[\$][0-9]+',
      'g') AS m2
  ) qq
  JOIN pg_attribute ae ON ae.attrelid = c2.oid
    AND ae.attname = qq.col
    AND NOT ae.attisdropped
    AND ae.attnum > 0
  WHERE qq.col <> raw.sortcol
    AND NOT fl.has_or
) ec
WHERE pg_relation_size(c2.oid) > 10 * 1024 * 1024
  AND NOT EXISTS (
    SELECT 1 FROM pg_index i2
    JOIN pg_attribute a6 ON a6.attrelid = i2.indrelid AND a6.attname = raw.sortcol
    WHERE i2.indrelid = c2.oid
      AND i2.indisvalid
      AND (i2.indkey::smallint[])[0] = a6.attnum
      AND ((i2.indpred IS NULL AND (raw.param_free OR ec.eq_cols IS NULL))
           OR replace(pg_get_expr(i2.indpred, i2.indrelid), ' ', '')
            = replace(raw.pred_clean, ' ', ''))
  )
  AND NOT (
    NOT raw.param_free
    AND ec.eq_attnums IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM pg_index i3
      WHERE i3.indrelid = c2.oid
        AND i3.indisvalid
        AND i3.indnkeyatts >= ec.eq_count + 1
        AND (i3.indkey::smallint[])[0:ec.eq_count - 1] <@ ec.eq_attnums
        AND (i3.indkey::smallint[])[ec.eq_count] = a3.attnum
    )
  );

INSERT INTO sugg
SELECT
  'MEDIUM', 'MEDIUM', 'Query spills to disk during sort/hash',
  t.queryid,
  NULL,
  NULL,
  'The query''s sort/hash step does not fit in memory and spills to disk. The default fix is restructuring (pre-aggregate, paginate before aggregation, narrower sort keys) — raising work_mem only relocates the cost into RAM.',
  'queryid=' || t.queryid || ' calls=' || t.calls
    || ' temp_written=' || pg_size_pretty((t.temp_blks_written * 8192)::bigint)
    || ' total_ms=' || t.total_exec_time::int,
  '$0 --deep-queryid=' || t.queryid,
  'n/a (no DDL)',
  'Spill volume is small relative to call frequency and latency is acceptable.',
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
\endif

INSERT INTO sugg
SELECT
  'HIGH', 'HIGH', 'Stale or missing planner statistics',
  NULL,
  x.fqname,
  'ANALYZE ' || x.fqname_q || ';',
  CASE WHEN x.never_analyzed
       THEN 'The table has never been analyzed or vacuumed (reltuples = -1): the planner guesses row counts from page counts, producing wrong scan and join choices that burn CPU. Plan-based suggestions in this report are unreliable for queries touching this table until ANALYZE runs.'
       ELSE 'A large fraction of rows changed since the last ANALYZE: row estimates are stale, producing wrong scan and join choices that burn CPU. Plan-based suggestions in this report are unreliable for queries touching this table until ANALYZE runs.' END,
  'n_live_tup=' || x.n_live_tup
    || ' n_mod_since_analyze=' || x.n_mod_since_analyze
    || ' reltuples=' || x.reltuples
    || ' last_analyzed=' || coalesce(x.last_analyzed::text, 'never')
    || ' total_size=' || x.size,
  'run ANALYZE, then re-run $0 --mode=suggestions — other suggestions may change',
  'ANALYZE only reads a row sample and takes a brief ShareUpdateExclusiveLock — safe, no data changes, no index builds. If a dead-tuple suggestion also targets this table, run VACUUM (ANALYZE) once instead of both commands.',
  'A bulk load or migration is still writing to this table — analyze after it finishes instead.',
  5
FROM (
  SELECT
    s.schemaname || '.' || s.relname AS fqname,
    quote_ident(s.schemaname) || '.' || quote_ident(s.relname) AS fqname_q,
    s.n_live_tup,
    s.n_mod_since_analyze,
    c.reltuples::bigint AS reltuples,
    greatest(s.last_analyze, s.last_autoanalyze) AS last_analyzed,
    pg_size_pretty(pg_total_relation_size(s.relid)) AS size,
    (c.reltuples < 0) AS never_analyzed
  FROM pg_stat_user_tables s
  JOIN pg_class c ON c.oid = s.relid
  WHERE s.schemaname NOT LIKE 'pg\_temp%'
    AND pg_relation_size(s.relid) > 10 * 1024 * 1024
    AND (c.reltuples < 0
         OR s.n_mod_since_analyze > greatest(0.2 * s.n_live_tup, 10000))
) x;

INSERT INTO sugg
SELECT
  CASE WHEN x.dead_pct > 50 THEN 'HIGH' ELSE 'MEDIUM' END,
  'MEDIUM',
  'Dead tuple bloat slowing scans',
  NULL,
  x.fqname,
  'VACUUM (ANALYZE) ' || x.fqname_q || ';',
  'Every scan must step over dead row versions before finding live rows — at '
    || x.dead_pct || '% dead, scans do roughly that much extra work. With default settings autovacuum should already have fired near 17% dead, so it is not keeping up on this table: a one-off VACUUM clears the backlog, but the durable fix is per-table tuning, e.g. ALTER TABLE ' || x.fqname_q || ' SET (autovacuum_vacuum_scale_factor = 0.02);',
  'n_dead_tup=' || x.n_dead_tup
    || ' dead_pct=' || x.dead_pct
    || ' last_autovacuum=' || coalesce(x.last_autovacuum::text, 'never')
    || ' total_size=' || x.size,
  're-run $0 --only=tables after VACUUM; if dead_pct climbs back within days, tune per-table autovacuum instead of repeating manual VACUUMs',
  'VACUUM generates read/write I/O while running and takes ShareUpdateExclusiveLock. It does not shrink the file (apart from trailing empty pages) — it makes the space reusable.',
  'A long-running or idle-in-transaction session is holding back cleanup (old backend_xmin) — VACUUM cannot remove those rows until it ends; check the idle transactions section of a full run first.',
  35
FROM (
  SELECT
    s.schemaname || '.' || s.relname AS fqname,
    quote_ident(s.schemaname) || '.' || quote_ident(s.relname) AS fqname_q,
    s.n_dead_tup,
    round(100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0), 1) AS dead_pct,
    s.last_autovacuum,
    pg_size_pretty(pg_total_relation_size(s.relid)) AS size
  FROM pg_stat_user_tables s
  WHERE s.schemaname NOT LIKE 'pg\_temp%'
    AND s.n_dead_tup > 10000
    AND pg_relation_size(s.relid) > 10 * 1024 * 1024
    AND 100.0 * s.n_dead_tup / NULLIF(s.n_live_tup + s.n_dead_tup, 0) > 30
) x;

INSERT INTO sugg
SELECT
  'MEDIUM',
  CASE WHEN bool_and(f.soft) THEN 'MEDIUM' ELSE 'HIGH' END,
  'Missing index on foreign key',
  NULL,
  f.child_table,
  string_agg(f.ddl, chr(10) ORDER BY f.conname),
  'These foreign-key columns have no covering btree index: joins on them scan the whole table, and DELETE/UPDATE on the referenced parent must scan this table to check the constraint.'
    || CASE WHEN bool_or(f.soft)
            THEN ' Parents marked (soft-delete) below are rarely hard-deleted — for those, index only if the column is used in joins.'
            ELSE '' END,
  string_agg(f.conname || ' → ' || f.parent
             || CASE WHEN f.soft THEN ' (soft-delete parent)' ELSE '' END,
             '; ' ORDER BY f.conname)
    || ' child_size=' || max(f.child_size)
    || ' child_writes=' || max(f.child_writes),
  'EXPLAIN (ANALYZE, BUFFERS) a join on these columns; re-run $0 --only=indexes after creating',
  'Every write to this table must also update each new index (writes become slightly slower).',
  'Parent rows are never hard-deleted or key-updated AND the join path is cold (soft-delete schemas often qualify).',
  30
FROM (
  SELECT
    n.nspname || '.' || cl.relname AS child_table,
    c.conname,
    rn.nspname || '.' || rcl.relname AS parent,
    'CREATE INDEX CONCURRENTLY IF NOT EXISTS '
      || quote_ident(pg_temp.idx_name(c.conname || '_idx'))
      || ' ON ' || quote_ident(n.nspname) || '.' || quote_ident(cl.relname)
      || ' (' ||
      (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY x.ord)
         FROM unnest(c.conkey) WITH ORDINALITY AS x(attnum, ord)
         JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = x.attnum)
      || ');' AS ddl,
    pg_size_pretty(pg_relation_size(c.conrelid)) AS child_size,
    coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) AS child_writes,
    EXISTS (
      SELECT 1 FROM pg_attribute pa
      WHERE pa.attrelid = c.confrelid
        AND pa.attname = 'deletedAt'
        AND NOT pa.attisdropped
    ) AS soft
  FROM pg_constraint c
  JOIN pg_class cl ON cl.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = cl.relnamespace
  JOIN pg_class rcl ON rcl.oid = c.confrelid
  JOIN pg_namespace rn ON rn.oid = rcl.relnamespace
  LEFT JOIN pg_stat_user_tables st ON st.relid = c.conrelid
  WHERE c.contype = 'f'
    AND (pg_relation_size(c.conrelid) > 10 * 1024 * 1024
         OR coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) > 100)
    AND NOT EXISTS (
      SELECT 1 FROM pg_index i
      JOIN pg_class ic ON ic.oid = i.indexrelid
      JOIN pg_am am ON am.oid = ic.relam AND am.amname IN ('btree', 'hash')
      WHERE i.indrelid = c.conrelid
        AND i.indisvalid
        AND i.indisready
        AND i.indpred IS NULL
        AND i.indnkeyatts >= cardinality(c.conkey)
        AND (i.indkey::smallint[])[0:cardinality(c.conkey) - 1] @> c.conkey::smallint[]
    )
) f
GROUP BY f.child_table;

INSERT INTO sugg
SELECT
  'CLEANUP', 'MEDIUM', 'Redundant index (covered by another)',
  NULL,
  n.nspname || '.' || t.relname,
  'DROP INDEX CONCURRENTLY ' || quote_ident(n.nspname) || '.' || quote_ident(ci1.relname) || ';',
  'Key columns are a leading prefix of ' || ci2.relname || ' with matching opclass, collation, and sort options. The covering index can serve the same queries.',
  'redundant=' || pg_get_indexdef(i1.indexrelid) || ' || covering=' || pg_get_indexdef(i2.indexrelid)
    || ' size=' || pg_size_pretty(pg_relation_size(i1.indexrelid)),
  'verify both definitions above, then DROP INDEX CONCURRENTLY; never urgent',
  'If the covering index is later dropped or made partial, this one may be needed again.',
  'The redundant index is referenced by name in code, or the covering index is itself a cleanup candidate.',
  50
FROM pg_index i1
JOIN pg_index i2 ON i1.indrelid = i2.indrelid AND i1.indexrelid <> i2.indexrelid
JOIN pg_class ci1 ON ci1.oid = i1.indexrelid
JOIN pg_class ci2 ON ci2.oid = i2.indexrelid
JOIN pg_class t ON t.oid = i1.indrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
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
       OR i1.indexrelid > i2.indexrelid);

INSERT INTO sugg
SELECT
  'CLEANUP', 'LOW', 'Unused index (no recorded scans)',
  NULL,
  s.schemaname || '.' || s.relname,
  'DROP INDEX CONCURRENTLY ' || quote_ident(s.schemaname) || '.' || quote_ident(s.indexrelname) || ';',
  'Zero scans since stats reset. The index is maintained on every write but no query has used it.',
  'def=' || pg_get_indexdef(i.indexrelid)
    || ' size=' || pg_size_pretty(pg_relation_size(s.indexrelid))
    || ' stats_since=' || sf.floor_ts::date
    || ' (' || extract(day FROM now() - sf.floor_ts)::int || ' days)',
  'confirm the stats window covers periodic jobs (monthly reports etc.), then DROP INDEX CONCURRENTLY; never urgent',
  'A periodic job outside the observation window may depend on it.',
  'The stats window is shorter than the longest reporting/job cycle that might use this index, or per-object counters were reset separately — db-level reset time is only a proxy.'
    || CASE WHEN now() - sf.floor_ts < interval '14 days'
            THEN ' STATS WINDOW < 14 DAYS — zero-scan evidence is weak; do not act on it yet.'
            ELSE '' END,
  60
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
CROSS JOIN LATERAL (
  SELECT coalesce(
    (SELECT sd.stats_reset FROM pg_stat_database sd WHERE sd.datname = current_database()),
    (SELECT min(io.stats_reset) FROM pg_stat_io io),
    now()) AS floor_ts
) sf
WHERE s.idx_scan = 0
  AND i.indisvalid
  AND NOT i.indisprimary
  AND NOT i.indisunique
  AND NOT i.indisexclusion
  AND NOT i.indisreplident
  AND NOT i.indisclustered
  AND NOT EXISTS (SELECT 1 FROM pg_constraint cc WHERE cc.conindid = i.indexrelid);

INSERT INTO sugg
SELECT
  'CLEANUP', 'MEDIUM', 'Disabled trigger still in schema',
  NULL,
  n.nspname || '.' || c.relname,
  'DROP TRIGGER ' || quote_ident(t.tgname) || ' ON '
    || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ';',
  'Trigger is disabled (tgenabled=D): it never fires but remains in the schema.',
  'def=' || pg_get_triggerdef(t.oid),
  'confirm it was not disabled temporarily (migration, bulk load), then drop',
  'Irreversible without the definition — it is preserved in the evidence above.',
  'It was disabled intentionally and will be re-enabled.',
  70
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND t.tgenabled = 'D';

INSERT INTO sugg
SELECT
  'CLEANUP', 'MEDIUM', 'Duplicate triggers',
  NULL,
  n.nspname || '.' || c.relname,
  NULL,
  'Multiple user triggers with identical timing, events, column list, WHEN clause, and arguments fire the same function: '
    || string_agg(t.tgname, ', ' ORDER BY t.tgname) || '. One is sufficient.',
  'function=' || p.proname || ' tgtype=' || t.tgtype,
  'inspect pg_get_triggerdef for each; drop one with DROP TRIGGER after verifying',
  'Irreversible without the definition — inspect and save it before dropping.',
  'The redundancy is intentional (e.g. created by separate migrations pending consolidation).',
  75
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_proc p ON p.oid = t.tgfoid
WHERE NOT t.tgisinternal
GROUP BY n.nspname, c.relname, p.proname, t.tgrelid, t.tgfoid, t.tgtype,
         t.tgattr::smallint[], pg_get_expr(t.tgqual, t.tgrelid), t.tgargs
HAVING count(*) > 1;

INSERT INTO sugg
SELECT
  'CLEANUP', 'LOW', 'Trigger on table with no writes',
  NULL,
  st.schemaname || '.' || st.relname || ' (' || t.tgname || ')',
  NULL,
  'Trigger never fires: the table has zero writes since stats reset. No runtime cost — schema noise only.',
  'writes=0 since stats reset; def=' || pg_get_triggerdef(t.oid),
  'confirm the table is truly unused before any schema cleanup',
  'n/a (informational)',
  'Writes are periodic (jobs, imports) outside the stats window.',
  80
FROM pg_trigger t
JOIN pg_stat_user_tables st ON st.relid = t.tgrelid
WHERE NOT t.tgisinternal
  AND st.n_tup_ins + st.n_tup_upd + st.n_tup_del = 0;

UPDATE sugg SET
  confidence = 'MEDIUM',
  do_not_apply_if = do_not_apply_if
    || ' NOTE: multiple ordered-index suggestions target this table — consolidate query shapes before adding all of them.'
WHERE category = 'Missing index for sorted pagination'
  AND objname IN (
    SELECT objname FROM sugg
    WHERE category = 'Missing index for sorted pagination'
    GROUP BY objname
    HAVING count(*) > 2
  );

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
\echo '── ranked suggestions ──'

SELECT format(E'\n%s. [%s] %s\n   severity: %s | confidence: %s%s\n   object:   %s\n   why:      %s\n   evidence: %s\n   verify:   %s\n   risk:     %s\n   do not apply if: %s\n   ${SQL_LABEL}:\n%s',
  rn,
  next_action,
  category,
  severity,
  confidence,
  coalesce(' | queryid=' || queryid, ''),
  coalesce(objname, '-'),
  reason,
  evidence,
  verify_cmd,
  risk,
  do_not_apply_if,
  coalesce('     ' || replace(sql_display, E'\n', E'\n     '), '     (no SQL for this suggestion)'))
FROM (
  SELECT s.*,
    CASE WHEN s.severity = 'CLEANUP' THEN 'OPTIONAL CLEANUP'
         WHEN s.confidence = 'HIGH' THEN 'TEST FIRST'
         WHEN s.confidence = 'MEDIUM' THEN 'VERIFY FIRST'
         ELSE 'INVESTIGATE ONLY' END AS next_action,
    CASE WHEN s.confidence = 'LOW'
              AND s.severity <> 'CLEANUP'
              AND s.suggested_sql IS NOT NULL
              AND ${SHOW_LOW_SQL} = 0
         THEN '(hidden — low confidence; rerun with --show-low-confidence-sql to see it)'
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
) r
ORDER BY rn;

\pset tuples_only off
\pset format aligned
SUGG_SQL
)"
  SUGG_RC=$?
  set -e

  ERR_COUNT="$(count_sql_errors "$SUGG_OUT")"

  if [[ $SUGG_RC -ne 0 || "${ERR_COUNT:-0}" -gt 0 ]]; then
    RUN_FAILED=1
    echo
    echo "╔═══════════════════════════════════════════════════════"
    echo "║  ⚠  This run hit ${ERR_COUNT:-?} SQL error(s) — suggestions could not"
    echo "║     be generated safely. Do not apply anything from this run."
    echo "╚═══════════════════════════════════════════════════════"
    if [[ "$DEBUG" == "1" ]]; then
      printf '%s\n' "$SUGG_OUT"
    else
      echo "   (raw partial output suppressed — rerun with --debug to inspect it)"
    fi
  else
    printf '%s\n' "$SUGG_OUT"
  fi

  if [[ $SUGG_RC -ne 0 ]]; then
    echo "   ⚠  Suggestions mode could not complete (lost the database connection mid-run — re-run)."
  fi
}
