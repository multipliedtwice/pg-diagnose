print_legend() {
  cat <<'LEGEND'
pg-diagnose — legend and methodology

output conventions
  unprefixed lines   data observed during this run
  warning lines (⚠)  condition-triggered, printed only when the condition applies
  this legend is the only static methodology text; reports do not repeat it

evidence classes (every section header carries one)
  window/sampled    what happened during this run (strongest)
  live snapshot     what is happening right now (strong)
  lifetime          totals since the last stats reset (medium)
  static            schema rules only, not observed behavior (weakest — verify manually)

suggestion tiers (the [bracket] on every instance)
  TEST FIRST        high confidence — ready to test on a staging copy
  VERIFY FIRST      plausible — verify the query plan before applying
  INVESTIGATE ONLY  weak evidence — candidate SQL hidden by default
                    (rerun with --show-low-confidence-sql to see it)
  OPTIONAL CLEANUP  housekeeping — never urgent, not a performance fix
                    (hidden by default; add --include-cleanup)

suggestions-mode methodology
  - evidence is lifetime pg_stat_statements + catalogs; window-level evidence
    requires a full run
  - statements are planned with EXPLAIN GENERIC_PLAN; on failure they are retried
    with typed literals rewritten to casts (interval $1 -> $1::interval, a form
    pgss normalization breaks), then with parameters replaced by NULL; rewritten
    plans are full generic plans, while null-param plans are used for operator
    detection only, never for selectivity-sensitive rules; statements with no
    plan at all are listed with the planner's error (section appears only when
    fallbacks occurred)
  - generic plans use default selectivity for parameters — est. rows are crude;
    design from table/column stats and verify with EXPLAIN ANALYZE on real params
  - active, enabled triggers are never judged droppable from statistics — only
    disabled, duplicate, and never-firing triggers are flagged
  - coverage: plan-shape rules detect GIN-able filters, GIN indexes the planner
    bypasses, trigram-able pattern filters, vector-distance sorts, sorted
    pagination (including existing ordered indexes the planner is not choosing),
    and disk spills; catalog rules detect stale statistics, dead tuples,
    unindexed foreign keys, expensive-ANALYZE vector columns, autoanalyze
    starvation, repeated expensive aggregates, WAL buffer saturation, redundant
    indexes, unique-key extensions, and unused indexes (>128kB, top 40 by size)
  - a plain missing btree index (WHERE col = $1 running as a Seq Scan) is NOT
    auto-suggested: generic plans make it false-positive-prone — start from the
    full run's heavy-seq-scans section, then --deep-queryid=<queryid>
  - SQL errors are isolated per rule: a failing rule is reported by name and its
    suggestions are omitted; all other suggestions remain valid

plan-driven index candidates (full run --only=indexes)
  Seq Scan + Filter            index on the filter columns
  Index/Bitmap scan + Filter   rows fetched then discarded; extend the index or
                               add a partial predicate
  large Sort                   index providing the order, or work_mem

prisma mode (--mode=prisma)
  - model and field names are emitted as raw table/column names — adjust manually
    where your schema uses @@map / @map
  - partial indexes require previewFeatures = ["partialIndexes"] (Prisma >= 7.4,
    preview — known migrate-dev drift bugs; verify prisma migrate dev stays in
    sync before adopting)
  - Prisma cannot create indexes CONCURRENTLY — the raw SQL stays attached to
    each index suggestion for large live tables
  - ANN indexes (hnsw/ivfflat) and trigram opclasses are not expressible in
    Prisma schema — they stay raw SQL (deliver via an edited migration file)
  - ANALYZE/VACUUM suggestions stay SQL (they are not schema changes)
  - per-suggestion caveats are embedded as // comments next to each translation

full-run notes
  - the window sampler commits per tick (no long-held snapshot); idle main-loop
    waits (wait_event_type=Activity) are excluded
  - backend_samples count per-backend: parallel workers multiply wall time, so
    percentages are shares of backend-samples, not wall-clock time
  - rates are divided by actual elapsed time, not the nominal window length
  - samples cover the whole cluster (all databases); pg_stat_statements deltas
    cover only the current database
  - pgss entries evicted AND recreated mid-window report lifetime totals as
    in-window
  - EXPLAIN ANALYZE is never auto-run; it executes the statement — wrap writes
    in BEGIN; ... ROLLBACK;
  - window and full-run sections tolerate SQL errors: a failing section is
    printed inline and the rest of the report continues (exit code becomes 1)
  - pg_stat_statements.track=top records only top-level statements; SQL issued
    inside functions/triggers is not recorded separately (track=all records it
    at extra cost)
  - pg_stat_io counts physical reads/writes: disk vs OS page-cache hits are
    indistinguishable; with io_method=worker (PG18 default) shared-buffer reads
    are attributed to the 'io worker' backend type, not the requesting backend

next steps
  ranked candidate actions:   ./pg-diagnose.sh --mode=suggestions
  one query in depth:         ./pg-diagnose.sh --deep-queryid=<queryid>
LEGEND
}