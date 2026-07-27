# Supabase schema

Source-controlled DDL for everything the game touches in the Supabase `public`
schema. `supabase/migrations/` is the system of record — CI applies it to the
hosted project on every merge to `main`, so a schema change ships with the code
that needs it and nobody pastes SQL into the dashboard.

```
supabase/
  migrations/     applied in filename order by `supabase db push` (CI)
  ci/             CI-only helpers — never run against the hosted project
  dump_schema.sql tool: reconstruct the whole public schema as ordered DDL
```

| Migration | Objects | Written/read by |
|-----------|---------|-----------------|
| `…_shot_events.sql` | `shot_events` table, `shot_heatmap` view | `CareerStatsReporter`, `PostGameAnalytics`, `CareerStatsScreen` |
| `…_career_stats.sql` | `career_stats` table, `career_totals` view, `career_totals_for()` + `recent_games_for()` RPCs | `CareerStatsReporter`, `CareerStatsScreen` |
| `…_bug_reports.sql` | `bug_reports` table | `BugReporter` / `BugReportDialog` |
| `…_network_sessions.sql` | `network_sessions` table, `network_session_health` + `match_health` views | `NetworkSessionReporter`; analysis via the views |

Order matters: `recent_games_for()` counts rows in `shot_events`, so the
timestamp prefixes keep that file first. The four are the **baseline** — the
schema as it stood when it was hand-applied, adopted wholesale rather than
re-derived. Treat them as history and never edit them; a change is a new
migration.

## Making a schema change

1. Add `supabase/migrations/<UTC timestamp>_<what_it_does>.sql`
   (`supabase migration new <name>` will name it for you).
2. Write it **idempotently** — `create … if not exists`, `add column if not
   exists`, drop-then-create for views, policies and constraints. CI enforces
   this by replaying every migration over a database that already has the
   objects; something that genuinely cannot be idempotent needs a `do $$ … $$`
   guard, not an exemption. This is what makes a half-applied migration
   recoverable by simply running it again.
3. If it changes a table the client reads, update `PlayerStats.to_dict()` /
   the reporter / the screen in the same change (see CLAUDE.md → *Where New
   Code Goes*).
4. Open the PR. `verify` builds a database from every migration in a throwaway
   container, exercises the views and RPCs (`ci/smoke.sql`), and replays them.
5. Merge. `push` applies the pending migrations to the hosted project.

PostgREST caches the schema; after a change that adds a column or an RPC it may
need `notify pgrst, 'reload schema';` before the client sees it.

## Enabling the pipeline

CI ships **inert**. The `push` and `drift` jobs look for one repo secret and
report-and-exit when it is missing, so nothing touches the live database until:

- **`SUPABASE_DB_URL`** — Dashboard → Project Settings → Database → Connection
  string → URI, with the password filled in. Use the **direct connection or the
  session pooler (port 5432)**, not the transaction pooler (6543): migrations
  are DDL in transactions, which transaction mode does not support. Add it under
  Settings → Secrets and variables → Actions.

The first real push is worth watching. Run the workflow manually
(`workflow_dispatch`) with `dry_run` left **true** to see exactly which
migrations it thinks are pending — that will be all four, because the hosted
project has the objects but no `supabase_migrations.schema_migrations` history.
Applying them is safe precisely because they are idempotent; the `verify` job's
replay step is the proof. Then re-run with `dry_run` false, or just merge.

To require a human before any apply, attach an
[environment](https://docs.github.com/actions/deployment/targeting-different-environments)
with a required reviewer to the `push` job.

## Drift

A weekly job rebuilds the schema from the migrations and diffs it against the
live one with `dump_schema.sql`; it fails on any difference and uploads both
dumps. That is what catches an out-of-band edit made in the SQL editor. Run it
on demand with `workflow_dispatch`. To reconcile a drift, fold the difference
into a new migration — or revert the hand-made change.

`dump_schema.sql` reconstructs columns from `pg_attrdef`, so it does not surface
identity columns' `generated … as identity` clause (e.g. `network_sessions.id`);
only sequence-backed defaults show. That is a known blind spot in the diff.

## Conventions

- **Identity is `steam_id`** on every table. There is no per-player `uuid`
  (`game_id` is still a UUID, minted client-side by `PlayerPrefs.generate_uuid`).
- **RLS** is on for all tables; the publishable (anon) key gets only the grants
  it needs (`bug_reports`/`network_sessions`: INSERT; `career_stats`/`shot_events`:
  INSERT + SELECT). There is deliberately **no UPDATE** grant anywhere — the anon
  key ships in every client binary, so an anon UPDATE let any player rewrite (or,
  via `steam_id = null`, wipe) every row. Do not re-add one; a stat merge that
  needs it must go through a service-role RPC. Reads for analysis go through the
  dashboard or a service-role key, which bypasses RLS.
- **Never commit the service/secret key**, and keep `SUPABASE_DB_URL` a repo
  secret — it carries the database password. Only the publishable key belongs in
  `SupabaseConfig`.
- Server-side CHECK constraints are the only guard against forged rows (the anon
  key is public and the client that enforces caps is one a hostile player
  controls). Bound new columns there too.

## `ci/`

Neither file is a migration; both would be wrong to run against the hosted
project.

- `ci/roles.sql` — creates `anon` / `authenticated` / `service_role` so the
  migrations' GRANTs work on a bare Postgres container. Supabase already has them.
- `ci/smoke.sql` — inserts a game, calls both RPCs, and checks the views return
  the right answers (it raises on a wrong one, not just on an error), then rolls
  back. `psql -f` alone proves only that the DDL parses; the RPC bodies and view
  expressions are what break when a column moves, and nothing else in CI runs them.
