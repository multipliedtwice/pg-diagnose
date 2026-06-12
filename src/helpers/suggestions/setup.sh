#!/usr/bin/env bash

emit_sugg_setup() {
  cat <<'SETUP_SQL'
CREATE TEMP TABLE sugg (
  severity text,
  confidence text,
  category text,
  queryid bigint,
  objname text,
  suggested_sql text,
  detail text,
  evidence text,
  verify_cmd text,
  sort int
);

CREATE FUNCTION pg_temp.idx_name(base text) RETURNS text
LANGUAGE sql AS $fn$
  SELECT CASE WHEN length(base) <= 63 THEN base
              ELSE left(base, 56) || '_' || left(md5(base), 6) END
$fn$;

CREATE FUNCTION pg_temp.conjunct_set(p text) RETURNS text[]
LANGUAGE plpgsql AS $fn$
DECLARE
  s text := trim(coalesce(p, ''));
  parts text[] := '{}';
  pieces text[] := '{}';
  cur text := '';
  piece text;
  depth int;
  i int;
  ch text;
  had_split bool := false;
BEGIN
  IF s = '' THEN RETURN '{}'; END IF;
  LOOP
    s := trim(s);
    EXIT WHEN s = '' OR left(s, 1) <> '(';
    depth := 0;
    i := 1;
    WHILE i <= length(s) LOOP
      ch := substr(s, i, 1);
      IF ch = '(' THEN depth := depth + 1;
      ELSIF ch = ')' THEN depth := depth - 1;
      END IF;
      EXIT WHEN depth = 0;
      i := i + 1;
    END LOOP;
    EXIT WHEN i < length(s);
    s := substr(s, 2, length(s) - 2);
  END LOOP;
  IF trim(s) = '' THEN RETURN '{}'; END IF;
  depth := 0;
  i := 1;
  WHILE i <= length(s) LOOP
    IF depth = 0 AND substr(s, i, 5) = ' AND ' THEN
      pieces := pieces || cur;
      cur := '';
      i := i + 5;
      had_split := true;
      CONTINUE;
    END IF;
    ch := substr(s, i, 1);
    IF ch = '(' THEN depth := depth + 1;
    ELSIF ch = ')' THEN depth := depth - 1;
    END IF;
    cur := cur || ch;
    i := i + 1;
  END LOOP;
  pieces := pieces || cur;
  IF NOT had_split THEN
    RETURN ARRAY[replace(trim(s), ' ', '')];
  END IF;
  FOREACH piece IN ARRAY pieces LOOP
    parts := parts || pg_temp.conjunct_set(piece);
  END LOOP;
  RETURN parts;
END
$fn$;

CREATE FUNCTION pg_temp.to_prisma(stmt text) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  m text[];
  cm text[];
  c text;
  attr text;
  parts text[] := '{}';
  notes text[] := '{}';
  body text;
BEGIN
  IF stmt ~* '^\s*(ANALYZE|VACUUM|ALTER\s+TABLE)' THEN
    RETURN trim(stmt) || E'\n// maintenance/storage command — run as SQL; there is no Prisma schema equivalent';
  END IF;
  IF stmt ~* '^\s*DROP\s+INDEX' THEN
    RETURN '// remove the matching @@index / @unique attribute from the model, then run: ' || trim(stmt);
  END IF;
  IF stmt ~* 'USING\s+(hnsw|ivfflat)' THEN
    RETURN '// ANN index — not expressible in Prisma schema; keep as raw SQL (edited migration file): ' || trim(stmt);
  END IF;
  IF stmt ~* 'gin_trgm_ops|gist_trgm_ops' THEN
    RETURN '// trigram opclass — not expressible in Prisma schema; keep as raw SQL: ' || trim(stmt);
  END IF;
  m := regexp_match(stmt,
    '^\s*CREATE\s+INDEX\s+CONCURRENTLY\s+IF\s+NOT\s+EXISTS\s+"?([A-Za-z0-9_]+)"?\s+ON\s+(?:"?[A-Za-z0-9_]+"?\.)?"?([A-Za-z0-9_]+)"?\s+(USING\s+gin\s+)?\(([^)]*)\)\s*(?:WHERE\s+(.+))?;\s*$',
    'i');
  IF m IS NULL THEN
    RETURN '// not translatable to Prisma schema — keep as raw SQL: ' || trim(stmt);
  END IF;
  FOREACH c IN ARRAY regexp_split_to_array(m[4], '\s*,\s*') LOOP
    cm := regexp_match(c,
      '^"?([A-Za-z0-9_]+)"?(\s+jsonb_path_ops)?(\s+(ASC|DESC))?(\s+NULLS\s+(FIRST|LAST))?\s*$', 'i');
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
    notes := notes || 'partial index: requires previewFeatures = ["partialIndexes"] (Prisma >= 7.4, preview — known migrate-dev drift bugs; verify migrations stay in sync or keep the raw SQL';
  END IF;
  notes := notes || ('Prisma cannot create indexes CONCURRENTLY — for a large live table run the raw SQL first, then baseline the migration: ' || trim(stmt));
  body := 'model ' || m[2] || ' {'
    || E'\n  @@index([' || array_to_string(parts, ', ') || ']'
    || ', map: "' || m[1] || '"'
    || CASE WHEN m[3] IS NOT NULL THEN ', type: Gin' ELSE '' END
    || CASE WHEN m[5] IS NOT NULL
            THEN ', where: raw("' || replace(replace(m[5], '\', '\\'), '"', '\"') || '")'
            ELSE '' END
    || ')' || E'\n}';
  RETURN body || E'\n// ' || array_to_string(notes, E'\n// ');
END
$fn$;

CREATE FUNCTION pg_temp.to_prisma_block(ddl text) RETURNS text
LANGUAGE sql AS $fn$
  SELECT string_agg(pg_temp.to_prisma(s), E'\n')
  FROM unnest(string_to_array(ddl, E'\n')) AS s
  WHERE length(trim(s)) > 0
$fn$;
SETUP_SQL
}