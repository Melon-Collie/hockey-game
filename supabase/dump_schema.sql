-- Schema dump helper. Run this in the Supabase SQL editor and copy the whole
-- `ddl` column out — it reconstructs the DDL for every object in the `public`
-- schema (tables, constraints, indexes, views, functions/RPCs, RLS policies)
-- as runnable-ish statements, ordered so a replay would build cleanly.
--
-- Why a single query: the SQL editor only displays the LAST statement's result
-- set, so everything is unioned into one text column instead of separate SELECTs.
--
-- This is the authoritative source for the source-controlled sql/*.sql files —
-- the client code only reveals columns it touches, not types/defaults/the view
-- + RPC bodies. Re-run any time the live schema drifts from the repo.

with table_ddl as (
    select 1 as sort, c.relname as obj,
        'create table public.' || c.relname || E' (\n' ||
        string_agg(
            '    ' || a.attname || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod)
            || coalesce(' default ' || pg_get_expr(ad.adbin, ad.adrelid), '')
            || case when a.attnotnull then ' not null' else '' end,
            -- BY NAME, not attnum. attnum is the order columns were physically
            -- added, which is history rather than schema: a table built in one
            -- shot from the migration's CREATE lists its columns in declared
            -- order, while the same logical table grown by `add column if not
            -- exists` has the late arrivals at the end. Both are the same schema
            -- — Postgres attaches no meaning to column order and nothing here
            -- selects positionally — but attnum order made them diff, so the
            -- drift check failed permanently against any historically-migrated
            -- database. Sorting by name makes the dump canonical.
            E',\n' order by a.attname
        ) || E'\n);' as ddl
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
    left join pg_attrdef ad on ad.adrelid = c.oid and ad.adnum = a.attnum
    where n.nspname = 'public' and c.relkind = 'r'
    group by c.relname
),
constraint_ddl as (
    select 2 as sort, conrelid::regclass::text as obj,
        'alter table ' || conrelid::regclass || ' add constraint ' || conname
        || ' ' || pg_get_constraintdef(oid) || ';' as ddl
    from pg_constraint
    where connamespace = 'public'::regnamespace
),
index_ddl as (
    select 3 as sort, tablename as obj, indexdef || ';' as ddl
    from pg_indexes
    where schemaname = 'public'
      and indexname not in (
          select conname from pg_constraint where connamespace = 'public'::regnamespace
      )
),
view_ddl as (
    select 4 as sort, table_name as obj,
        'create or replace view public.' || table_name || E' as\n'
        || pg_get_viewdef(('public.' || table_name)::regclass, true) as ddl
    from information_schema.views
    where table_schema = 'public'
),
func_ddl as (
    select 5 as sort, p.proname as obj, pg_get_functiondef(p.oid) || ';' as ddl
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
),
rls_ddl as (
    select 6 as sort, c.relname as obj,
        'alter table public.' || c.relname || ' enable row level security;' as ddl
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
),
policy_ddl as (
    select 7 as sort, tablename as obj,
        'create policy ' || quote_ident(policyname) || ' on public.' || tablename
        || ' as ' || lower(permissive)
        || ' for ' || lower(cmd)
        || ' to ' || array_to_string(roles, ', ')
        || coalesce(E'\n    using (' || qual || ')', '')
        || coalesce(E'\n    with check (' || with_check || ')', '') || ';' as ddl
    from pg_policies
    where schemaname = 'public'
)
select '-- ' || sort || ' · ' || obj || E'\n' || ddl as ddl
from (
    select * from table_ddl
    union all select * from constraint_ddl
    union all select * from index_ddl
    union all select * from view_ddl
    union all select * from func_ddl
    union all select * from rls_ddl
    union all select * from policy_ddl
) x
-- `ddl` breaks the tie. Without it, objects sharing a (sort, obj) — a table's
-- several constraints or indexes — come back in whatever order the catalog scan
-- produced, so two dumps of the SAME schema could differ by line order alone.
-- The drift check in .github/workflows/supabase.yml diffs two of these against
-- each other, and a hand reconcile is no easier against a shuffled file.
order by sort, obj, ddl;
