-- career_stats — one row per player per online game, posted at game-over by
-- CareerStatsReporter (Scripts/game/career_stats_reporter.gd). The Career screen
-- reads lifetime totals from the career_totals view and per-game history from
-- the recent_games_for() RPC.
--
-- Source of truth for a fresh rebuild; the live DB was reconstructed from
-- sql/dump_schema.sql. Identity is steam_id; there is no per-player uuid (rows
-- key on steam_id everywhere).
--
-- Adding a career stat: new column here → add to career_totals below → add to
-- PlayerStats.to_dict() → add a row in CareerStatsScreen._on_totals_received.

create table if not exists public.career_stats (
    id             bigserial primary key,
    steam_id       bigint,
    player_name    text,
    game_version   text,
    played_at      timestamptz default now(),
    goals          integer default 0,
    assists        integer default 0,
    shots_on_goal  integer default 0,
    hits           integer default 0,
    toi_seconds    integer default 0,
    goals_for      integer default 0,
    goals_against  integer default 0,
    outcome        text,
    shots_blocked  integer default 0 not null,
    game_id        uuid,
    team_id        smallint,
    created_at     timestamptz not null default now(),
    period_scores  jsonb,
    num_periods    smallint
);

create index if not exists career_stats_game_id_idx on public.career_stats (game_id);

-- RLS: the publishable (anon) key may INSERT and SELECT only. There is NO update
-- policy — the anon key ships in every client binary, so an anon UPDATE grant let
-- any player rewrite (or, via steam_id = null, wipe) every row's career. No client
-- code ever issued an UPDATE; if slot-swap stat merges are ever needed they must
-- go through a service-role RPC, not the anon key. SELECT is intentionally open —
-- career data is leaderboard-grade public (rosters surface in recent_games_for).
-- The career_totals view runs security_invoker, so it re-checks the select policy.
alter table public.career_stats enable row level security;

drop policy if exists "anon insert" on public.career_stats;
create policy "anon insert" on public.career_stats for insert to anon with check (true);
drop policy if exists "anon select" on public.career_stats;
create policy "anon select" on public.career_stats for select to anon using (true);
-- The former "anon update" policy is intentionally removed — do NOT re-add it.
drop policy if exists "anon update" on public.career_stats;

-- Anti-abuse constraints: the anon key is public, so these are the only
-- server-side guard against forged / oversized inserts (client-side caps live in
-- a binary a hostile client controls). Bounds are generous — they reject garbage
-- (negative counts, megabyte blobs), not legitimate blowouts. Drop-then-add for
-- idempotent re-runs, matching the policy pattern above.
alter table public.career_stats drop constraint if exists career_stats_sane_ranges;
alter table public.career_stats add constraint career_stats_sane_ranges check (
    goals         between 0 and 1000  and
    assists       between 0 and 1000  and
    shots_on_goal between 0 and 5000  and
    hits          between 0 and 5000  and
    shots_blocked between 0 and 5000  and
    toi_seconds   between 0 and 100000 and
    goals_for     between 0 and 1000  and
    goals_against between 0 and 1000  and
    (num_periods  is null or num_periods  between 1 and 20) and
    (player_name  is null or length(player_name)  <= 64) and
    (game_version is null or length(game_version) <= 64) and
    (outcome      is null or length(outcome)      <= 16) and
    pg_column_size(period_scores) < 4096
);

-- ── Lifetime totals (career screen, Career Totals tab) ───────────────────────
create or replace view public.career_totals
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

-- ── Per-game history (career screen, Recent Games tab) ───────────────────────
-- Returns the games a given player appeared in, newest first, each with the
-- full per-player roster as nested JSON.
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

grant execute on function public.recent_games_for(bigint, integer) to anon;
