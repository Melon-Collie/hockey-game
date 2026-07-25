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
    faceoff_wins   integer default 0 not null,
    faceoff_losses integer default 0 not null,
    -- Analytics A1. Per-player shot-attempt volume (individual Corsi/Fenwick);
    -- team_sog_* are team quantities carried on every row (like goals_for), the
    -- PDO denominators. Fenwick = shot_attempts − shot_attempts_blocked.
    shot_attempts         integer default 0 not null,
    shot_attempts_blocked integer default 0 not null,
    team_sog_for          integer default 0 not null,
    team_sog_against      integer default 0 not null,
    -- Analytics A2. xg_for = individual expected goals (ixG); team_xg_* are team
    -- quantities carried on every row, the career xGF% numerator/denominator.
    xg_for                numeric default 0 not null,
    team_xg_for           numeric default 0 not null,
    team_xg_against       numeric default 0 not null,
    -- Offline (vs bots) matches count toward the career exactly like online ones
    -- — most play happens offline and a career that ignores it isn't the player's
    -- career. This records which a row WAS, so the two remain separable later
    -- (a human-only leaderboard, say) without having gated the upload. Older rows
    -- predate offline uploads and are all online, hence the `true` default.
    is_online             boolean default true not null,
    -- Peak human headcount in the match — stronger than is_online, since an
    -- online lobby nobody joined is a bot game with extra steps. A COUNT rather
    -- than a "ranked" flag: Mitts has no ranked mode, and a count lets a later
    -- query pick its own bar (1 = solo vs bots, >= 2 = a real opponent, 6 = a
    -- full lobby) instead of inheriting a threshold baked in at write time.
    -- Backfilled to 2 for pre-existing rows: they all passed the old two-human
    -- upload gate, so >= 2 is known true for them, though the exact count is
    -- unrecoverable. Peak, not final, so someone who drops before the horn still
    -- counts.
    human_players         integer default 2 not null
);

-- Migration for an existing DB (the create above is skipped once the table
-- exists). Safe to re-run — IF NOT EXISTS makes each ADD idempotent.
alter table public.career_stats add column if not exists hits_taken     integer default 0 not null;
alter table public.career_stats add column if not exists takeaways      integer default 0 not null;
alter table public.career_stats add column if not exists giveaways      integer default 0 not null;
alter table public.career_stats add column if not exists faceoff_wins   integer default 0 not null;
alter table public.career_stats add column if not exists faceoff_losses integer default 0 not null;
alter table public.career_stats add column if not exists shot_attempts         integer default 0 not null;
alter table public.career_stats add column if not exists shot_attempts_blocked integer default 0 not null;
alter table public.career_stats add column if not exists team_sog_for          integer default 0 not null;
alter table public.career_stats add column if not exists team_sog_against      integer default 0 not null;
alter table public.career_stats add column if not exists xg_for                numeric default 0 not null;
alter table public.career_stats add column if not exists team_xg_for           numeric default 0 not null;
alter table public.career_stats add column if not exists team_xg_against       numeric default 0 not null;
alter table public.career_stats add column if not exists is_online             boolean default true not null;
-- Default 2 backfills existing rows honestly: every one of them passed the old
-- two-human upload gate (see the column comment above).
alter table public.career_stats add column if not exists human_players         integer default 2 not null;

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
    hits_taken    between 0 and 5000  and
    takeaways     between 0 and 5000  and
    giveaways     between 0 and 5000  and
    faceoff_wins  between 0 and 5000  and
    faceoff_losses between 0 and 5000  and
    shot_attempts         between 0 and 10000 and
    shot_attempts_blocked between 0 and 10000 and
    team_sog_for          between 0 and 10000 and
    team_sog_against      between 0 and 10000 and
    xg_for                between 0 and 10000 and
    team_xg_for           between 0 and 10000 and
    team_xg_against       between 0 and 10000 and
    human_players         between 0 and 64 and
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
-- DROP + CREATE (not CREATE OR REPLACE): replacing a view can only APPEND
-- trailing columns, never reorder, so adding columns anywhere but the very end
-- of the live view's existing order errors ("cannot change name of view column
-- ..."). Dropping first sidesteps that regardless of the current column order.
-- Nothing depends on career_totals (the anon client just SELECTs it), so no
-- cascade; the grant below restores the anon read the drop removes.
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
    round(sum(goals + assists)::numeric / NULLIF(sum(toi_seconds), 0)::numeric * 3600::numeric, 2) AS points_per_60,
    -- New sums appended at the END: CREATE OR REPLACE VIEW can only add trailing
    -- columns, never reorder existing ones (else it errors renaming a column).
    sum(hits_taken) AS hits_taken,
    sum(takeaways) AS takeaways,
    sum(giveaways) AS giveaways,
    sum(faceoff_wins) AS faceoff_wins,
    sum(faceoff_losses) AS faceoff_losses,
    round(sum(faceoff_wins)::numeric / NULLIF(sum(faceoff_wins) + sum(faceoff_losses), 0)::numeric * 100::numeric, 1) AS faceoff_pct,
    -- Analytics A1: lifetime advanced stats. iCF = shot attempts; Fenwick =
    -- attempts − blocked. PDO = on-ice shooting% + save%, ×1000 (SH% from the
    -- player's team goals/SOG, SV% from goals-against / SOG-against).
    sum(shot_attempts) AS shot_attempts,
    sum(shot_attempts - shot_attempts_blocked) AS fenwick,
    round((
        sum(goals_for)::numeric     / NULLIF(sum(team_sog_for), 0)::numeric
      + 1::numeric - sum(goals_against)::numeric / NULLIF(sum(team_sog_against), 0)::numeric
    ) * 1000::numeric, 0) AS pdo,
    -- Analytics A2: lifetime xG. ixG = summed expected goals; goals − ixG is
    -- finishing (goals above expected); xGF% is team chance-share.
    round(sum(xg_for), 2) AS xg_for,
    round(sum(goals)::numeric - sum(xg_for), 2) AS goals_above_expected,
    round(sum(team_xg_for) / NULLIF(sum(team_xg_for) + sum(team_xg_against), 0) * 100::numeric, 1) AS xgf_pct
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
        'faceoff_losses', cs.faceoff_losses,
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
