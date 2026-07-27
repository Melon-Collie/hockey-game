# Supabase schema

Source-controlled DDL for everything the game touches in the Supabase `public`
schema. The live database is the system of record; these files mirror it so the
schema is reviewable, diffable, and rebuildable. Apply a file by pasting it into
the Supabase SQL editor (Dashboard → SQL). Each file is self-contained (table +
indexes + RLS + policies, plus any view/RPC for that feature) and idempotent
(`create … if not exists`, `create or replace`, `drop policy if exists`).

| File | Objects | Written/read by |
|------|---------|-----------------|
| `shot_events.sql` | `shot_events` table, `shot_heatmap` view | `CareerStatsReporter`, `PostGameAnalytics`, `CareerStatsScreen` |
| `career_stats.sql` | `career_stats` table, `career_totals` view, `career_totals_for()` + `recent_games_for()` RPCs | `CareerStatsReporter`, `CareerStatsScreen` |
| `bug_reports.sql` | `bug_reports` table | `BugReporter` / `BugReportDialog` |
| `network_sessions.sql` | `network_sessions` table, `network_session_health` view | `NetworkSessionReporter`; analysis via the view |
| `dump_schema.sql` | — (tool) | Run it to regenerate the files above from the live DB |

Apply `shot_events.sql` BEFORE `career_stats.sql` — `recent_games_for()` counts
rows in `shot_events`, so it does not stand alone on a fresh database.

## Conventions

- **Identity is `steam_id`** on every table. There is no per-player `uuid`
  (`game_id` is still a UUID, minted client-side by `PlayerPrefs.generate_uuid`).
- **RLS** is on for all tables; the publishable (anon) key gets only the grants
  it needs (`bug_reports`/`network_sessions`: INSERT; `career_stats`/`shot_events`:
  INSERT + SELECT). There is deliberately **no UPDATE** grant anywhere — the anon
  key ships in every client binary, so an anon UPDATE let any player rewrite (or,
  via `steam_id = null`, wipe) every row. Do not re-add one; a stat merge that
  needs it must go through a service-role RPC. Reads for analysis go through the
  dashboard or a service-role key, which bypasses RLS. Never commit the
  service/secret key.

## Keeping in sync

When the live schema changes, update the matching file here in the same change.
To detect drift or recapture after an out-of-band edit, run `dump_schema.sql` in
the SQL editor and reconcile its output against these files.

> Note: `dump_schema.sql` reconstructs columns from `pg_attrdef`, so it does not
> surface identity columns' `generated … as identity` clause (e.g.
> `network_sessions.id`) — only sequence-backed defaults show. Fold that back in
> by hand when reconciling.
