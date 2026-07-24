-- shot_events — one row per resolved shot attempt (analytics plan B1). Posted in
-- a single batch by the HOST at game-over (CareerStatsReporter.report_shot_events),
-- since the host holds the authoritative per-game shot log (AdvancedStatsTracker).
-- Feeds the post-game shot map / xG-flow and the career heatmap.
--
-- Identity: steam_id is the shooter (0 for bots — the career heatmap filters them
-- out naturally); game_id ties a game's shots together. Same anon-key trust model
-- and version-controlled-schema convention as career_stats (see that file's notes).

create table if not exists public.shot_events (
    id           bigserial primary key,
    game_id      uuid,
    steam_id     bigint,          -- shooter; 0 for a bot
    team_id      smallint,
    x            numeric,         -- release position, rink coordinates
    z            numeric,
    xg           numeric default 0 not null,
    outcome      text,            -- 'goal' | 'saved' | 'missed' | 'blocked'
    shot_type    text,            -- 'shot' | 'one_timer' | 'tip'
    on_net       boolean default false not null,
    period       smallint,
    clock_s      numeric,         -- period time remaining at the shot
    game_version text,
    created_at   timestamptz not null default now()
);

create index if not exists shot_events_game_id_idx on public.shot_events (game_id);
create index if not exists shot_events_steam_id_idx on public.shot_events (steam_id);

-- RLS: anon may INSERT and SELECT only (mirrors career_stats — no UPDATE, the anon
-- key ships in every client). SELECT is open; shot data is leaderboard-grade public.
alter table public.shot_events enable row level security;

drop policy if exists "anon insert" on public.shot_events;
create policy "anon insert" on public.shot_events for insert to anon with check (true);
drop policy if exists "anon select" on public.shot_events;
create policy "anon select" on public.shot_events for select to anon using (true);

-- Anti-abuse bounds (the only server-side guard against forged/oversized inserts).
-- Generous — reject garbage, not legitimate values. Rink is ~30 m half-length /
-- ~15 m half-width, so ±40 covers any legal release with margin.
alter table public.shot_events drop constraint if exists shot_events_sane_ranges;
alter table public.shot_events add constraint shot_events_sane_ranges check (
    x  between -40 and 40 and
    z  between -40 and 40 and
    xg between 0 and 1 and
    (period  is null or period  between 1 and 20) and
    (clock_s is null or clock_s between 0 and 100000) and
    (outcome   is null or outcome   in ('goal', 'saved', 'missed', 'blocked')) and
    (shot_type is null or shot_type in ('shot', 'one_timer', 'tip')) and
    (game_version is null or length(game_version) <= 64)
);

-- ── Career heatmap source ────────────────────────────────────────────────────
-- Per-player shot density on a 1 m grid: count, summed xG, and goals per bucket.
-- The career heatmap reads this filtered by steam_id (bots, steam_id 0, are their
-- own harmless bucket the screen ignores). DROP + CREATE per the career_stats note.
drop view if exists public.shot_heatmap;
create view public.shot_heatmap
with (security_invoker = true) as
 SELECT steam_id,
    round(x)::int AS bucket_x,
    round(z)::int AS bucket_z,
    count(*) AS shots,
    round(sum(xg), 3) AS xg,
    sum(CASE WHEN outcome = 'goal'::text THEN 1 ELSE 0 END) AS goals
   FROM shot_events
  WHERE steam_id IS NOT NULL
  GROUP BY steam_id, round(x)::int, round(z)::int;

grant select on public.shot_heatmap to anon;
