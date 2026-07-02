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
    num_periods    smallint,
    hits_taken     integer default 0 not null,
    takeaways      integer default 0 not null,
    giveaways      integer default 0 not null,
    faceoff_wins   integer default 0 not null
);

-- Migration for an existing DB (the create above is skipped once the table
-- exists). Safe to re-run — IF NOT EXISTS makes each ADD idempotent.
alter table public.career_stats add column if not exists hits_taken   integer default 0 not null;
alter table public.career_stats add column if not exists takeaways    integer default 0 not null;
alter table public.career_stats add column if not exists giveaways    integer default 0 not null;
alter table public.career_stats add column if not exists faceoff_wins integer default 0 not null;

create index if not exists career_stats_game_id_idx on public.career_stats (game_id);

-- RLS: the publishable (anon) key inserts rows, selects its own career, and
-- updates (slot-swap stat merges). The career_totals view runs security_invoker,
-- so anon's SELECT is gated by the anon-select policy below.
alter table public.career_stats enable row level security;

drop policy if exists "anon insert" on public.career_stats;
create policy "anon insert" on public.career_stats for insert to anon with check (true);
drop policy if exists "anon select" on public.career_stats;
create policy "anon select" on public.career_stats for select to anon using (true);
drop policy if exists "anon update" on public.career_stats;
create policy "anon update" on public.career_stats for update to anon using (true);

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
    sum(hits_taken) AS hits_taken,
    sum(takeaways) AS takeaways,
    sum(giveaways) AS giveaways,
    sum(faceoff_wins) AS faceoff_wins,
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
        'hits_taken',    cs.hits_taken,
        'takeaways',     cs.takeaways,
        'giveaways',     cs.giveaways,
        'faceoff_wins',  cs.faceoff_wins,
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
