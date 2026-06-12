# pg-diagnose

Read-only PostgreSQL CPU and performance diagnosis for PostgreSQL 18+, oriented
toward DigitalOcean Managed PostgreSQL. It only reads statistics: it never runs
DDL and never modifies data.

## Requirements

- A `psql` client (libpq) on the machine you run it from.
- Bash 4+.
- A PostgreSQL 18+ server. The script refuses to run against older servers.
- `pg_stat_statements` is recommended. Without it, query-history, suggestion,
  and deep-query phases degrade or are skipped; catalog-based checks still run.
- For the `doctl` config hints to be useful, set `DB_CLUSTER_ID` to your
  DigitalOcean cluster id. The diagnosis itself runs against any PG18 server.

## Run on a server (no clone, no Node)

Fetch a pinned release asset once, then run it as often as you like:

    curl -sSL -o pg-diagnose.sh \
      https://github.com/<you>/pg-diagnose/releases/download/v0.1.0/pg-diagnose.sh
    chmod +x pg-diagnose.sh

    DATABASE_URL='postgresql://user:pass@host:port/db?sslmode=require' \
    DB_CLUSTER_ID='<cluster-id>' \
      ./pg-diagnose.sh

Pin to a release tag (`v0.1.0`), not a branch, so a push never changes what
runs against your database.

## Usage

Each command is self-contained — prefix the connection string and run. Avoid
pasting passwords inline in your shell: export `DATABASE_URL` from a secrets
store or use `~/.pgpass`, otherwise the credential lands in shell history.
The script exits non-zero if any section or mode failed, so it can be used
in automation.

**1. Full health check** — every phase, no log by default
(add `--output-dir=/tmp/pg-diagnose` to save one; last 5 logs are kept):

    DATABASE_URL="postgresql://doadmin:PASSWORD@db-postgresql-sgp1-xxxxx-do-user-xxxxxxxx-0.k.db.ondigitalocean.com:25060/db?sslmode=require" ./pg-diagnose.sh

**2. Ranked fixes to verify** — the usual starting point; prints candidate DDL with evidence, executes nothing:

    DATABASE_URL="postgresql://doadmin:PASSWORD@...:25060/db?sslmode=require" ./pg-diagnose.sh --mode=suggestions

**3. Fixes plus housekeeping** — also lists unused/redundant indexes and disabled/duplicate triggers:

    DATABASE_URL="postgresql://doadmin:PASSWORD@...:25060/db?sslmode=require" ./pg-diagnose.sh --mode=suggestions --include-cleanup

**4. Sample a live CPU spike** — only the sampled window phase, over two minutes:

    DATABASE_URL="postgresql://doadmin:PASSWORD@...:25060/db?sslmode=require" SAMPLE_SECONDS=120 ./pg-diagnose.sh --only=window

**5. Historical heavy hitters** — skip the live phases:

    DATABASE_URL="postgresql://doadmin:PASSWORD@...:25060/db?sslmode=require" ./pg-diagnose.sh --only=history,tables,indexes

**6. Drill into one query** — queryid comes from the output of 2, 4, or 5:

    DATABASE_URL="postgresql://doadmin:PASSWORD@...:25060/db?sslmode=require" ./pg-diagnose.sh --deep-queryid=8123456789012345678

Phases: `config snapshot window progress history io tables indexes triggers`.
Run `./pg-diagnose.sh --help` for the full option and environment-variable list.

## Development

Source lives in `src/`, split by responsibility:

    src/lib/common.sh     globals, psql wrappers, run_section, phase_enabled
    src/lib/args.sh       usage text and argument parsing
    src/lib/detect.sh     server capability detection (version, pg_stat_statements)
    src/helpers/          banner, explain, deep, suggestions
    src/phases/           one file per diagnostic phase
    src/main.sh           main() orchestration and run_cli() entry
    src/MODULES           load order, single source of truth

`pg-diagnose.sh` at the repo root runs the split source directly by sourcing
the files listed in `src/MODULES`. Use it during development:

    DATABASE_URL='...' ./pg-diagnose.sh --only=config

`build.sh` concatenates the same modules, in the same `src/MODULES` order, into
a single `dist/pg-diagnose.sh`. That bundled file is what gets distributed and
run on servers, because Bash cannot source remote files over HTTP. `dist/` is
generated and gitignored — it is never committed; `src/` is the only source.

    ./build.sh
    bash -n dist/pg-diagnose.sh   # syntax check the bundle

## Releases

Releases are built in CI on tag push (`.github/workflows/release.yml`). The
workflow bundles `src/` into `dist/pg-diagnose.sh`, syntax-checks it, and
attaches it as the release asset. You do not build or commit the bundle by hand.

    git tag v0.1.0
    git push --tags

The attached asset is then available at the pinned URL shown in
"Run on a server" above.

## Safety

The script reads from system catalogs and statistics views only. `EXPLAIN
ANALYZE` is never auto-run; suggestion and index phases print candidate DDL but
never execute it.

## License

See `LICENSE`.