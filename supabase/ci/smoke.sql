-- CI-ONLY smoke test. NOT a migration — it writes rows, so it must only ever run
-- against the throwaway CI database. Wrapped in a transaction that always rolls
-- back, but the guard that matters is the workflow: it targets a container.
--
-- Why this exists: the migrations create four tables, four views and two RPCs,
-- and `psql -f` proves only that the DDL PARSES. The parts that actually break
-- when a column moves are the RPC bodies and the view expressions — a renamed
-- column or a changed type surfaces here and nowhere else, because nothing else
-- in CI ever executes them. Each check raises on a wrong answer rather than
-- merely running, so a silently-empty result is a failure too.

begin;

insert into public.career_stats
    (steam_id, player_name, game_id, team_id, goals, assists, shots_on_goal,
     toi_seconds, goals_for, goals_against, outcome, team_size,
     faceoff_wins, faceoff_losses, shot_attempts, shot_attempts_blocked,
     team_sog_for, team_sog_against, xg_for, team_xg_for, team_xg_against,
     period_scores, num_periods)
values
    (1001, 'Smoke Home', '11111111-1111-1111-1111-111111111111', 0,
     2, 1, 5, 900, 4, 2, 'win', 3, 6, 4, 11, 2, 20, 14, 1.5, 3.2, 2.1,
     '[[1,2,1],[1,0,1]]'::jsonb, 3),
    (1002, 'Smoke Away', '11111111-1111-1111-1111-111111111111', 1,
     1, 0, 3, 900, 2, 4, 'loss', 3, 4, 6, 7, 1, 14, 20, 0.8, 2.1, 3.2,
     '[[1,2,1],[1,0,1]]'::jsonb, 3);

insert into public.shot_events
    (game_id, steam_id, team_id, x, z, xg, outcome, shot_type, on_net,
     period, clock_s, team_size)
values
    ('11111111-1111-1111-1111-111111111111', 1001, 0,  1.5, -24.0, 0.42, 'goal',   'shot',      true,  1, 540.0, 3),
    ('11111111-1111-1111-1111-111111111111', 1001, 0, -3.0, -18.0, 0.09, 'saved',  'one_timer', true,  2, 300.0, 3),
    ('11111111-1111-1111-1111-111111111111', 1002, 1,  0.5,  25.0, 0.55, 'missed', 'tip',       false, 3, 120.0, 3);

do $$
declare
    r record;
    n int;
begin
    -- career_totals_for: pooled, then filtered by roster size.
    select * into r from public.career_totals_for(1001, null);
    if r.games_played <> 1 or r.goals <> 2 or r.points <> 3 then
        raise exception 'career_totals_for(pooled) wrong: games=% goals=% points=%',
            r.games_played, r.goals, r.points;
    end if;
    if r.faceoff_pct is null or r.xgf_pct is null or r.pdo is null then
        raise exception 'career_totals_for derived ratios null: fo=% xgf=% pdo=%',
            r.faceoff_pct, r.xgf_pct, r.pdo;
    end if;

    select count(*) into n from public.career_totals_for(1001, 5);
    if n <> 0 then
        raise exception 'career_totals_for(team_size=5) should not match a 3v3 game, got % rows', n;
    end if;

    -- recent_games_for: one game, both rosters nested, shot count joined.
    select * into r from public.recent_games_for(1001, 20);
    if r.home_score <> 4 or r.away_score <> 2 then
        raise exception 'recent_games_for score wrong: %-%', r.home_score, r.away_score;
    end if;
    if jsonb_array_length(r.players) <> 2 then
        raise exception 'recent_games_for should nest both players, got %',
            jsonb_array_length(r.players);
    end if;
    if r.shot_count <> 3 then
        raise exception 'recent_games_for shot_count wrong: %', r.shot_count;
    end if;
    if r.outcome <> 'win' then
        raise exception 'recent_games_for outcome should be the CALLER''s: %', r.outcome;
    end if;

    -- shot_heatmap: attacking-end normalised, so team 1's shot folds into
    -- team 0's frame — (0.5, 25.0) must land at (-1, -25), not (1, 25).
    select count(*) into n from public.shot_heatmap
        where steam_id = 1002 and bucket_x = -1 and bucket_z = -25;
    if n <> 1 then
        raise exception 'shot_heatmap did not fold team 1 into the attacking frame';
    end if;

    -- The remaining views must at least execute against real rows.
    perform count(*) from public.career_totals;
    perform count(*) from public.network_session_health;
    perform count(*) from public.match_health;
end
$$;

-- ── Security posture ─────────────────────────────────────────────────────────
-- Two classes of view, and the difference is deliberate:
--   career_totals / shot_heatmap    — readable with the anon key (leaderboard).
--   network_session_health / match_health — NOT readable; telemetry is for the
--       dashboard and service-role only (see the network_sessions migration).
-- Both classes must be invoker-rights. A SECURITY DEFINER view runs as its owner
-- and bypasses the underlying RLS entirely, which is how the telemetry views
-- leaked until 20260727181500 — the Supabase advisor flags it, and by then it is
-- already live. These are catalog assertions rather than role-switching queries,
-- so they hold no matter which superuser CI connects as.
do $$
declare
    v text;
begin
    foreach v in array array[
        'network_session_health', 'match_health', 'career_totals', 'shot_heatmap'
    ] loop
        if not exists (
            select 1 from pg_class c
            join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relname = v
              and c.reloptions @> array['security_invoker=true']
        ) then
            raise exception
                'view public.% is not security_invoker — it would bypass RLS', v;
        end if;
    end loop;

    -- Telemetry stays unreadable with the publishable key, which ships in every
    -- client binary.
    foreach v in array array['network_session_health', 'match_health'] loop
        if has_table_privilege('anon', 'public.' || v, 'SELECT') then
            raise exception
                'anon can SELECT public.% — telemetry is not world-readable', v;
        end if;
    end loop;

    -- ...and the public ones stay public, so a blanket revoke never silently
    -- breaks the career screen.
    foreach v in array array['career_totals', 'shot_heatmap'] loop
        if not has_table_privilege('anon', 'public.' || v, 'SELECT') then
            raise exception 'anon cannot SELECT public.% — the career screen reads it', v;
        end if;
    end loop;

    -- The tables the client posts to: RLS on, and no anon SELECT on telemetry.
    if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                   where n.nspname = 'public' and c.relname = 'network_sessions'
                     and c.relrowsecurity) then
        raise exception 'RLS is not enabled on network_sessions';
    end if;
    if exists (select 1 from pg_policies where schemaname = 'public'
               and tablename = 'network_sessions' and cmd = 'SELECT'
               and 'anon' = any(roles)) then
        raise exception 'network_sessions has an anon SELECT policy — it is INSERT-only';
    end if;
end
$$;

rollback;
