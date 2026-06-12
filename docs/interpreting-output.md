# Interpreting pg-diagnose output

The canonical legend ships with the script: `./pg-diagnose.sh --legend` prints the
same content as this page and works without a database connection. This page
exists so the legend is readable without downloading the script.

## Output conventions

Unprefixed lines are data observed during the run. Lines starting with `⚠` are
condition-triggered warnings — they appear only when the condition applies to
your cluster. Static methodology text is never repeated inside reports; it lives
here and in `--legend`.

## Evidence classes

Every section header carries one of these:

| class | meaning | strength |
|---|---|---|
| window/sampled | what happened during this run | strongest |
| live snapshot | what is happening right now | strong |
| lifetime | totals since the last stats reset | medium |
| static | schema rules only, not observed behavior | weakest — verify manually |

## Suggestion tiers

| tier | meaning |
|---|---|
| TEST FIRST | high confidence — ready to test on a staging copy |
| VERIFY FIRST | plausible — verify the query plan before applying |
| INVESTIGATE ONLY | weak evidence — candidate SQL hidden by default (`--show-low-confidence-sql`) |
| OPTIONAL CLEANUP | housekeeping — never urgent, not a performance fix (`--include-cleanup`) |

Suggestions are grouped by category. The category header carries the rationale
(`why`), `risk`, and `do not apply if` — these are templates shared by all
instances. Everything under an instance line (`object`, `note`, `evidence`,
`verify`, suggested SQL) is data from your cluster.

## Suggestions-mode methodology

- Evidence is lifetime `pg_stat_statements` plus catalogs; window-level evidence
  requires a full run.
- Statements are planned with `EXPLAIN (GENERIC_PLAN)`. On failure they are
  retried with typed literals rewritten to casts (`interval $1` →
  `$1::interval`, a form pgss normalization breaks), then with parameters
  replaced by `NULL`. Rewritten plans are full generic plans; null-param plans
  are used for operator detection only, never for selectivity-sensitive rules.
  Statements with no plan at all are listed with the planner's error (the
  section appears only when fallbacks occurred).
- Generic plans use default selectivity for parameters — estimated rows are
  crude. Design from table/column statistics and verify with
  `EXPLAIN ANALYZE` on real parameter values.
- Active, enabled triggers are never judged droppable from statistics — only
  disabled, duplicate, and never-firing triggers are flagged.
- Coverage: plan-shape rules detect GIN-able filters, GIN indexes the planner
  bypasses, trigram-able pattern filters, vector-distance sorts, sorted
  pagination (including existing ordered indexes the planner is not choosing),
  and disk spills. Catalog rules detect stale statistics, dead tuples,
  unindexed foreign keys, expensive-ANALYZE vector columns, autoanalyze
  starvation, repeated expensive aggregates, WAL buffer saturation, redundant
  indexes, unique-key extensions, and unused indexes (>128kB, top 40 by size).
- A plain missing btree index (`WHERE col = $1` running as a Seq Scan) is NOT
  auto-suggested: generic plans make it false-positive-prone. Start from the
  full run's heavy-seq-scans section, then `--deep-queryid=<queryid>`.
- SQL errors are isolated per rule: a failing rule is reported by name and its
  suggestions are omitted; all other suggestions remain valid.

## Prisma mode

`--mode=prisma` renders index changes as Prisma `@@index` attributes where
expressible, with caveats embedded as `//` comments next to each translation:
`@@map`/`@map` adjustments are manual; partial indexes need the
`partialIndexes` preview feature; Prisma cannot create indexes CONCURRENTLY;
ANN and trigram indexes stay raw SQL; ANALYZE/VACUUM stays SQL.

## Full-run notes

The window sampler commits per tick (no long-held snapshot) and excludes idle
main-loop waits (`wait_event_type=Activity`). `backend_samples` counts
per-backend, so parallel workers multiply wall time — percentages are shares of
backend-samples, not wall-clock. Rates divide by actual elapsed time. Samples
cover the whole cluster; pg_stat_statements deltas cover only the current
database. pgss entries evicted and recreated mid-window report lifetime totals
as in-window. `EXPLAIN ANALYZE` is never auto-run; it executes the statement —
wrap writes in `BEGIN; ... ROLLBACK;`.