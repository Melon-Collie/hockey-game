-- bug_reports — one row per in-game bug report, posted fire-and-forget by
-- BugReporter (Scripts/game/bug_reporter.gd) from the BugReportDialog. Carries a
-- telemetry snapshot (incl. build_id) in the jsonb blob so a report pins the
-- exact build and connection state it came from.
--
-- Source of truth for a fresh rebuild; live DB reconstructed from
-- sql/dump_schema.sql. Identity is steam_id (0 = offline / free-play, i.e.
-- anonymous); there is no per-player uuid.

create table if not exists public.bug_reports (
    id            bigserial primary key,
    steam_id      bigint,
    player_name   text,
    game_version  text,
    platform      text,
    submitted_at  timestamptz default now(),
    description   text,
    telemetry     jsonb
);

-- RLS: the publishable (anon) key may INSERT only. Reads happen from the
-- dashboard / a service-role key (bypasses RLS); the publishable key only
-- authorizes INSERT, so spam can't be cleaned up server-side — keep the
-- BugReporter rate limit + length cap as the first line of defense.
alter table public.bug_reports enable row level security;

drop policy if exists "anon insert" on public.bug_reports;
create policy "anon insert" on public.bug_reports for insert to anon with check (true);
