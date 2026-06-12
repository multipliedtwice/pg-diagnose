#!/usr/bin/env bash

phase_triggers() {
  echo
  echo "╔═══════════════════════════════════════════════════════"
  echo "║   Trigger overhead (evidence: lifetime)"
  echo "╚═══════════════════════════════════════════════════════"
  if [[ "$TRACK_FUNC" == "none" ]]; then
    echo "   (track_functions=none — per-function timing below will be empty;"
    echo "    see the config phase for how to enable it)"
  fi

  run_section "triggers by table write volume (every write fires these)" "
  SELECT
    n.nspname || '.' || c.relname AS table,
    t.tgname AS trigger,
    p.proname AS function,
    CASE t.tgenabled WHEN 'D' THEN 'DISABLED' ELSE 'enabled' END AS status,
    coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) AS table_writes,
    f.calls AS fn_calls,
    f.total_time::int AS fn_total_ms,
    round((f.self_time / NULLIF(f.calls, 0))::numeric, 2) AS fn_mean_ms
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  LEFT JOIN pg_stat_user_tables st ON st.relid = c.oid
  LEFT JOIN pg_stat_user_functions f ON f.funcid = p.oid
  WHERE NOT t.tgisinternal
  ORDER BY coalesce(st.n_tup_ins + st.n_tup_upd + st.n_tup_del, 0) DESC, 1, 2;
  " -x

  run_list "disabled triggers (never fire, still in schema)" "none" "
  SELECT format('  %s on %s.%s', t.tgname, n.nspname, c.relname)
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE NOT t.tgisinternal
    AND t.tgenabled = 'D'
  ORDER BY 1;
  "

  run_list "duplicate triggers (identical timing/events/function — one is sufficient)" "none" "
  SELECT format('  %s.%s → %s fires %s (%s copies)',
                n.nspname, c.relname,
                string_agg(t.tgname, ', ' ORDER BY t.tgname),
                p.proname, count(*))
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE NOT t.tgisinternal
  GROUP BY n.nspname, c.relname, p.proname, t.tgrelid, t.tgfoid, t.tgtype,
           t.tgattr::smallint[], pg_get_expr(t.tgqual, t.tgrelid), t.tgargs
  HAVING count(*) > 1
  ORDER BY 1;
  "
}
