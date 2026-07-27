-- Close a real hole flagged by the Supabase advisor: `network_session_health`
-- and `match_health` were created without `with (security_invoker = true)`, so
-- they defaulted to SECURITY DEFINER and ran with the view OWNER's privileges —
-- which bypasses row-level security on `network_sessions` underneath.
--
-- That contradicts the posture the network_sessions migration states outright:
-- "the publishable (anon) key may INSERT only. Reads happen from the dashboard /
-- a service-role key — telemetry isn't world-readable." The table enforces it
-- (RLS on, an INSERT policy and deliberately no SELECT policy), but a
-- definer-rights view over it hands back every row regardless, and Supabase
-- grants `anon` privileges on new objects in `public` by default. The anon key
-- ships inside every client binary, so anyone with a copy of the game could read
-- other players' telemetry — player names, platforms, and full session metrics.
-- `career_totals` / `shot_heatmap` were already invoker-rights and are meant to
-- be readable (leaderboard-grade), so they are untouched.
--
-- ALTER rather than drop-and-recreate: the two view bodies are ~150 lines of
-- documented metric extraction, and restating them here to change one option
-- would fork the definition and invite drift. Setting the option in place cannot
-- change what the views return.
alter view public.network_session_health set (security_invoker = true);
alter view public.match_health           set (security_invoker = true);

-- Belt and braces. With invoker rights the RLS policy already yields zero rows
-- to `anon`, but that leaves the guarantee resting entirely on a policy staying
-- absent. Revoking the default grant states the intent in the privilege system
-- itself, so a future SELECT policy added to network_sessions for some other
-- purpose cannot silently re-open these views. Service-role and the dashboard
-- are unaffected (they bypass RLS and hold their own grants).
revoke all on public.network_session_health from anon, authenticated;
revoke all on public.match_health           from anon, authenticated;
