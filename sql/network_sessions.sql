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
    game_id        text,         -- cross-peer match UUID: joins the host row with its clients' rows (same id as career_stats)
    end_reason     text,         -- 'completed' | 'quit' | 'host_lost' | 'host_ended' | 'kicked'
    metrics        jsonb         -- full aggregate blob from NetworkSessionSummary.to_dict()
);

-- Columns added after the original deploy — ADD COLUMN IF NOT EXISTS upgrades
-- an existing table in place (CREATE TABLE IF NOT EXISTS alone won't).
alter table public.network_sessions add column if not exists game_id    text;
alter table public.network_sessions add column if not exists end_reason text;

create index if not exists network_sessions_created_at_idx on public.network_sessions (created_at desc);
create index if not exists network_sessions_version_idx    on public.network_sessions (game_version);
create index if not exists network_sessions_game_id_idx    on public.network_sessions (game_id);

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
    (game_id        is null or length(game_id)      <= 64) and
    (end_reason     is null or length(end_reason)   <= 32) and
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
    (metrics->>'extrapolation_per_sec_max')::float   as guessing_ahead_peak,   -- RAW /s, scales with client fps; prefer the _pct fields below
    (metrics->>'sim_rate_hz_min')::float             as sim_rate_min,        -- host only
    (metrics->>'worst_stall_ms_max')::float          as worst_stall_ms,      -- host only
    (metrics->>'input_starvations_per_sec_max')::float as starvations_peak,  -- host only
    (metrics->>'bytes_recv_per_sec_avg')::float / 1024.0 as down_kbps_avg,
    (metrics->>'bytes_sent_per_sec_avg')::float / 1024.0 as up_kbps_avg,
    -- Appended after the original columns: `create or replace view` can only ADD
    -- trailing columns, never reorder/rename existing ones (a mid-list insert
    -- errors with "cannot change name of view column"). Keep new columns here.
    (metrics->>'extrapolation_pct_avg')::float        as guessing_ahead_pct_avg,  -- % of frames extrapolating (framerate-independent)
    (metrics->>'extrapolation_pct_max')::float        as guessing_ahead_pct_peak,
    (metrics->>'client_fps_avg')::float               as client_fps_avg,          -- effective render rate; contextualizes the raw per-sec rates
    (metrics->>'client_fps_min')::float               as client_fps_min,
    -- Reconcile-cause attribution: which channel drives residual reconcile churn
    -- on a clean link (see #4 / the trajectory-reconcile diagnosis).
    (metrics->>'recon_pos_per_sec_avg')::float          as recon_pos_avg,
    (metrics->>'recon_vel_per_sec_avg')::float          as recon_vel_avg,
    (metrics->>'recon_ubody_per_sec_avg')::float        as recon_ubody_avg,
    (metrics->>'recon_pos_offset_ticks_avg')::float     as recon_pos_offset_ticks_avg,
    (metrics->>'recon_post_replay_residual_m_avg')::float as recon_post_replay_residual_avg,
    -- Match join key + how the session ended ('completed' vs the abnormal ends
    -- the old game-over-only reporter never saw), then the rare-event tripwire
    -- TOTALS (session sums — averaging smears 3 hard snaps to ~0/s) and the
    -- buffer/broadcast health added to the fold. Trailing-append rule applies.
    game_id,
    end_reason,
    (metrics->>'puck_hard_snaps_total')::float           as puck_hard_snaps_total,   -- client only; genuine host/client physics divergence
    (metrics->>'blade_jumps_total')::float               as blade_jumps_total,       -- client only; reconcile-induced blade teleports
    (metrics->>'buffer_depth_skater_min')::float         as buffer_skater_min,       -- client only; 0 = interp buffer ran dry
    (metrics->>'buffer_depth_puck_min')::float           as buffer_puck_min,         -- client only
    (metrics->>'broadcast_interval_p95_ms_max')::float   as broadcast_gap_p95_peak,  -- host only; snapshot send cadence sag
    -- Link-quality disambiguation + clock health + objective anomaly markers.
    (metrics->>'delay_spread_ms_avg')::float             as delay_spread_avg,        -- client only; read with jitter: jitter high + this low = clumping (benign)
    (metrics->>'delay_spread_ms_max')::float             as delay_spread_peak,
    (metrics->>'clock_correction_ms_max')::float         as clock_correction_peak,   -- client only; sustained large = clock sync unstable (poisons lag comp)
    (metrics->>'worst_peer_rtt_ms_avg')::float           as worst_peer_rtt_avg,      -- host only; the host row's real link picture
    (metrics->>'worst_peer_loss_pct_max')::float         as worst_peer_loss_peak,    -- host only
    (metrics->>'auto_marker_count')::int                 as auto_marker_count,       -- objective tripwire firings (markers themselves in metrics->'auto_markers')
    -- Lag-comp pickup-claim health (host only; the host processes every client's
    -- claim). misses/claims ≈ rewind accuracy: near-zero = the rewound blade/puck
    -- reproduce what the client saw; a high fraction = the rewind is off (the
    -- "reached for it, didn't get it" symptom). deflects = reached but not catchable.
    (metrics->>'pickup_claims_total')::float             as pickup_claims_total,
    (metrics->>'pickup_claim_misses_total')::float       as pickup_claim_misses_total,
    (metrics->>'pickup_claim_deflects_total')::float     as pickup_claim_deflects_total,
    -- Client-side optimistic-pickup outcomes (the felt "grab, then lose it"). A pin
    -- is the visual attach; timeouts = the host silently declined and it rolled back
    -- (the felt bug), stolen = a different carrier legitimately won it. Watch
    -- timeouts / pins: the pin-predicate gate should drive it toward 0. Client only.
    (metrics->>'provisional_pins_total')::float          as provisional_pins_total,
    (metrics->>'provisional_confirmed_total')::float     as provisional_confirmed_total,
    (metrics->>'provisional_timeouts_total')::float      as provisional_timeouts_total,
    (metrics->>'provisional_stolen_total')::float        as provisional_stolen_total,
    -- Lag-comp poke / stick-lift claim health (host only), same read as the pickup
    -- claim columns: misses/claims ≈ how often the host's rewind disagreed with the
    -- client's in-range view for a stick-on-stick check. Trailing-append (see below).
    (metrics->>'poke_claims_total')::float               as poke_claims_total,
    (metrics->>'poke_claim_misses_total')::float         as poke_claim_misses_total,
    (metrics->>'stick_lift_claims_total')::float         as stick_lift_claims_total,
    (metrics->>'stick_lift_claim_misses_total')::float   as stick_lift_claim_misses_total,
    -- Reconcile-match health. A find_at miss falls back to the (prediction-lead)
    -- live position and trips a spurious position snap, so a low match AVG (vs the
    -- MIN, which one post-faceoff window can own) is the residual-churn driver. The
    -- miss totals attribute it: EMPTY/OLDER = post-clear transient (benign), GAP =
    -- a real hole in the prediction history (the bug to chase). gap_ms_peak is the
    -- worst ack-vs-history-bound distance seen (large ⇒ clear-related, small ⇒ off-by-one).
    (metrics->>'reconcile_match_pct_avg')::float         as reconcile_match_avg,     -- client only; pairs with reconcile_match_min
    (metrics->>'reconcile_miss_empty_total')::float      as reconcile_miss_empty_total,
    (metrics->>'reconcile_miss_older_total')::float      as reconcile_miss_older_total,
    (metrics->>'reconcile_miss_newer_total')::float      as reconcile_miss_newer_total,
    (metrics->>'reconcile_miss_gap_total')::float        as reconcile_miss_gap_total,
    (metrics->>'reconcile_miss_gap_ms_max')::float       as reconcile_miss_gap_ms_peak,
    -- Shot-launch divergence (client only): client-predicted vs host-authoritative
    -- puck at the first host-confirmed broadcast after a local release. Both run
    -- identical Jolt from the same client-sent origin, so the peak should be small
    -- (RTT jitter); a large peak = real launch divergence, and it's the shot-launch
    -- slice of puck_hard_snaps. Read the peaks against shot_launches_total (denominator).
    (metrics->>'shot_launch_div_m_max')::float           as shot_launch_div_peak,     -- m; worst launch position gap
    (metrics->>'shot_launch_vel_div_max')::float         as shot_launch_vel_div_peak,  -- m/s; worst launch velocity gap
    (metrics->>'shot_launches_total')::float             as shot_launches_total        -- shots measured (denominator)
from public.network_sessions
where net_sim_active is not true;

-- ── Per-match view ───────────────────────────────────────────────────────────
-- One row per MATCH: the host row joined with its clients' rows via game_id.
-- This is the triage unit — netcode failure modes are asymmetric (a host
-- stall shows as worst_stall on the host row but as reconcile/extrapolation
-- spikes on every client row; client→host input loss shows as host-side
-- starvation), so they only become legible with both sides in one record.
-- "Worst client" aggregates deliberately take the worst value across the
-- lobby: one bad experience is a bad match. Starting points:
--   select * from match_health where abnormal_ends > 0 order by started_at desc;
--   select * from match_health order by worst_client_hard_snaps desc nulls last limit 20;
create or replace view public.match_health as
select
    game_id,
    min(created_at)                                        as started_at,
    max(game_version)                                      as game_version,
    count(*) filter (where role = 'host')                  as host_rows,
    count(*) filter (where role = 'client')                as client_rows,
    max(duration_sec)                                      as duration_sec,
    sum(felt_lag_count)                                    as felt_lag_total,
    count(*) filter (where end_reason is distinct from 'completed') as abnormal_ends,
    -- host frame / send health (null when the host row is missing)
    min(sim_rate_min)           filter (where role = 'host') as host_sim_rate_min,
    max(worst_stall_ms)         filter (where role = 'host') as host_worst_stall_ms,
    max(starvations_peak)       filter (where role = 'host') as host_starvations_peak,
    max(broadcast_gap_p95_peak) filter (where role = 'host') as host_broadcast_gap_p95,
    -- worst client experience across the lobby
    max(rtt_avg)                filter (where role = 'client') as worst_client_rtt_avg,
    max(loss_avg)               filter (where role = 'client') as worst_client_loss_avg,
    max(reconcile_avg)          filter (where role = 'client') as worst_client_reconcile_avg,
    min(reconcile_match_min)    filter (where role = 'client') as worst_client_recon_match_min,
    max(guessing_ahead_pct_avg) filter (where role = 'client') as worst_client_extrap_pct_avg,
    max(puck_hard_snaps_total)  filter (where role = 'client') as worst_client_hard_snaps,
    max(blade_jumps_total)      filter (where role = 'client') as worst_client_blade_jumps,
    min(buffer_skater_min)      filter (where role = 'client') as worst_client_buffer_min,
    -- Trailing-append rule applies here too (create or replace view).
    sum(auto_marker_count)                                     as auto_marker_total,
    max(delay_spread_peak)      filter (where role = 'client') as worst_client_delay_spread,
    max(clock_correction_peak)  filter (where role = 'client') as worst_client_clock_correction,
    -- Host-side lag-comp pickup-claim health for the match (one host per game).
    -- Read misses relative to claims: high misses/claims flags a rewind that
    -- isn't reproducing what clients saw when they reached for a loose puck.
    max(pickup_claims_total)         filter (where role = 'host') as host_pickup_claims,
    max(pickup_claim_misses_total)   filter (where role = 'host') as host_pickup_claim_misses,
    max(pickup_claim_deflects_total) filter (where role = 'host') as host_pickup_claim_deflects,
    -- Poke / stick-lift claim health for the match (one host per game). Same read
    -- as the pickup columns: high misses/claims flags a rewind not reproducing what
    -- clients saw when they poked / hooked a carrier's stick.
    max(poke_claims_total)             filter (where role = 'host') as host_poke_claims,
    max(poke_claim_misses_total)       filter (where role = 'host') as host_poke_claim_misses,
    max(stick_lift_claims_total)       filter (where role = 'host') as host_stick_lift_claims,
    max(stick_lift_claim_misses_total) filter (where role = 'host') as host_stick_lift_claim_misses
from public.network_session_health
where game_id is not null
group by game_id;
