-- network_sessions — one row per online game, posted at game-over by
-- NetworkSessionReporter (Scripts/game/network_session_reporter.gd).
--
-- Purpose: F3 shows a tester their LIVE connection, but only they can see it.
-- This table ships each session's worst/typical connection numbers back so the
-- whole tester pool can be aggregated to find what actually causes lag, jitter,
-- and bad netcode — the data-driven answer F3 alone can't give.
--
-- Run this in the Supabase SQL editor (Dashboard → SQL). Idempotent-ish:
-- CREATE TABLE IF NOT EXISTS, CREATE OR REPLACE VIEW.
--
-- The evolving per-metric aggregate set ("<key>_max/_avg/_min", felt-lag
-- markers) lives in the `metrics` jsonb so adding a metric in
-- network_session_summary.gd never needs an ALTER TABLE. Only identity/filter
-- fields are typed columns.

create table if not exists public.network_sessions (
    id             bigint generated always as identity primary key,
    created_at     timestamptz not null default now(),
    steam_id       int8,
    player_name    text,
    game_version   text,
    platform       text,
    role           text,         -- 'host' | 'client'
    net_sim_active boolean,      -- true = dev session w/ artificial lag; exclude from analysis
    duration_sec   integer,
    felt_lag_count integer,      -- subjective "I felt lag" presses this session
    metrics        jsonb         -- full aggregate blob from NetworkSessionSummary.to_dict()
);

create index if not exists network_sessions_created_at_idx on public.network_sessions (created_at desc);
create index if not exists network_sessions_version_idx    on public.network_sessions (game_version);

-- RLS: the publishable (anon) key may INSERT only. Reads happen from the
-- dashboard / a service-role key, which bypasses RLS — telemetry isn't
-- world-readable. Mirrors the bug_reports posture.
alter table public.network_sessions enable row level security;

drop policy if exists network_sessions_anon_insert on public.network_sessions;
create policy network_sessions_anon_insert
    on public.network_sessions
    for insert
    to anon
    with check (true);

-- Anti-abuse caps: INSERT is public via the anon key, so bound the numeric fields
-- and the metrics blob against forged / oversized rows. Generous ranges — reject
-- garbage, not real sessions. Drop-then-add for idempotent re-runs.
alter table public.network_sessions drop constraint if exists network_sessions_sane_sizes;
alter table public.network_sessions add constraint network_sessions_sane_sizes check (
    (duration_sec   is null or duration_sec   between 0 and 100000) and
    (felt_lag_count is null or felt_lag_count between 0 and 100000) and
    (player_name    is null or length(player_name)  <= 64) and
    (game_version   is null or length(game_version) <= 64) and
    (platform       is null or length(platform)     <= 64) and
    (role           is null or length(role)         <= 16) and
    pg_column_size(metrics) < 65536
);

-- ── Analysis view ────────────────────────────────────────────────────────────
-- Flattens the headline metrics out of the jsonb into typed columns so you can
-- sort/aggregate without json casts everywhere. Excludes dev (net_sim) rows.
-- "Biggest causes of lag" starting points:
--   select platform, count(*), round(avg(rtt_avg)) avg_ping, round(avg(loss_avg),2) avg_loss,
--          round(avg(reconcile_avg),2) avg_corrections
--     from network_session_health group by platform order by avg_corrections desc;
--   select * from network_session_health where felt_lag_count > 0 order by created_at desc;
create or replace view public.network_session_health as
select
    id, created_at, player_name, game_version, platform, role,
    duration_sec, felt_lag_count,
    (metrics->>'rtt_ms_avg')::float                  as rtt_avg,
    (metrics->>'rtt_ms_max')::float                  as rtt_peak,
    (metrics->>'packet_loss_pct_avg')::float         as loss_avg,
    (metrics->>'packet_loss_pct_max')::float         as loss_peak,
    (metrics->>'jitter_p95_ms_avg')::float           as jitter_avg,
    (metrics->>'jitter_p95_ms_max')::float           as jitter_peak,
    (metrics->>'reconcile_per_sec_avg')::float       as reconcile_avg,
    (metrics->>'reconcile_per_sec_max')::float       as reconcile_peak,
    (metrics->>'reconcile_mag_m_max')::float         as reconcile_mag_peak,
    (metrics->>'reconcile_match_pct_min')::float     as reconcile_match_min,
    (metrics->>'extrapolation_per_sec_max')::float   as guessing_ahead_peak,
    (metrics->>'sim_rate_hz_min')::float             as sim_rate_min,        -- host only
    (metrics->>'worst_stall_ms_max')::float          as worst_stall_ms,      -- host only
    (metrics->>'input_starvations_per_sec_max')::float as starvations_peak,  -- host only
    (metrics->>'bytes_recv_per_sec_avg')::float / 1024.0 as down_kbps_avg,
    (metrics->>'bytes_sent_per_sec_avg')::float / 1024.0 as up_kbps_avg
from public.network_sessions
where net_sim_active is not true;
