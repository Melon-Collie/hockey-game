-- One-time migration: drop the now-redundant `uuid` columns. Identity is
-- steam_id everywhere; the uuid column was a steam-derived reshaping of the same
-- id (CareerStatsReporter/BugReporter used to send PlayerPrefs.career_uuid(),
-- now removed). Run this in the Supabase SQL editor, and ship the matching
-- client build together — until a client updates, its fire-and-forget POSTs
-- that still send `uuid` will 4xx and fail silently (no crash, a few stat rows
-- lost during the rollout window).
--
-- Order matters: career_totals (view) and recent_games_for (function) reference
-- career_stats.uuid, so they're rebuilt WITHOUT it before the column is dropped
-- (Postgres blocks dropping a column a view depends on). CREATE OR REPLACE VIEW
-- can't remove a column, so the view is dropped + recreated — which loses its
-- grant, re-added below.

begin;

-- 1. Rebuild the RPC without 'uuid' in the players JSON (replace preserves grants).
create or replace function public.recent_games_for(player_steam_id bigint, game_limit integer default 20)
 returns table(game_id uuid, ended_at timestamptz, home_score integer, away_score integer,
               num_periods integer, period_scores jsonb, players jsonb, game_version text)
 language sql
 stable
as $function$
  SELECT
    cs.game_id,
    MAX(cs.created_at)                                                              AS ended_at,
    MAX(CASE WHEN cs.team_id = 0 THEN cs.goals_for ELSE cs.goals_against END)::int  AS home_score,
    MAX(CASE WHEN cs.team_id = 1 THEN cs.goals_for ELSE cs.goals_against END)::int  AS away_score,
    MAX(cs.num_periods)::int                                                        AS num_periods,
    (array_agg(cs.period_scores))[1]                                               AS period_scores,
    jsonb_agg(
      jsonb_build_object(
        'player_name',   cs.player_name,
        'team_id',       cs.team_id,
        'goals',         cs.goals,
        'assists',       cs.assists,
        'shots_on_goal', cs.shots_on_goal,
        'hits',          cs.hits,
        'shots_blocked', cs.shots_blocked,
        'plus_minus',    cs.goals_for - cs.goals_against,
        'toi_seconds',   cs.toi_seconds,
        'outcome',       cs.outcome
      )
      ORDER BY cs.team_id, cs.player_name
    )                                                                              AS players,
    MAX(cs.game_version)                                                            AS game_version
  FROM career_stats cs
  WHERE cs.game_id IN (
    SELECT DISTINCT cs2.game_id FROM career_stats cs2
    WHERE cs2.steam_id = player_steam_id AND cs2.game_id IS NOT NULL
  )
  GROUP BY cs.game_id
  ORDER BY ended_at DESC
  LIMIT game_limit;
$function$;

-- 2. Rebuild career_totals without the `uuid` column (drop + recreate, since
--    CREATE OR REPLACE VIEW can't drop a column). security_invoker keeps anon's
--    SELECT gated by the career_stats anon-select policy.
drop view if exists public.career_totals;
create view public.career_totals
with (security_invoker = true) as
 SELECT steam_id,
    (array_agg(player_name ORDER BY played_at DESC NULLS LAST))[1] AS player_name,
    count(*) AS games_played,
    sum(goals) AS goals,
    sum(assists) AS assists,
    sum(goals + assists) AS points,
    sum(shots_on_goal) AS shots_on_goal,
    sum(hits) AS hits,
    sum(shots_blocked) AS shots_blocked,
    sum(toi_seconds) AS toi_seconds,
    sum(goals_for) AS goals_for,
    sum(goals_against) AS goals_against,
    sum(goals_for - goals_against) AS plus_minus,
    sum(CASE WHEN outcome = 'win'::text THEN 1 ELSE 0 END) AS wins,
    sum(CASE WHEN outcome = 'loss'::text THEN 1 ELSE 0 END) AS losses,
    round(sum(goals)::numeric / NULLIF(sum(toi_seconds), 0)::numeric * 3600::numeric, 2) AS goals_per_60,
    round(sum(assists)::numeric / NULLIF(sum(toi_seconds), 0)::numeric * 3600::numeric, 2) AS assists_per_60,
    round(sum(goals + assists)::numeric / NULLIF(sum(toi_seconds), 0)::numeric * 3600::numeric, 2) AS points_per_60
   FROM career_stats
  WHERE steam_id IS NOT NULL
  GROUP BY steam_id;

grant select on public.career_totals to anon;

-- 3. Drop the redundant columns.
alter table public.career_stats     drop column if exists uuid;
alter table public.bug_reports      drop column if exists uuid;
alter table public.network_sessions drop column if exists uuid;

commit;
