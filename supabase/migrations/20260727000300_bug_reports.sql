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

-- Anti-abuse size caps: INSERT is public via the anon key, and the client-side
-- length caps (BugReporter.MAX_DESCRIPTION_CHARS etc.) live in a binary a hostile
-- client controls. These are the only server-side guard against megabyte-payload
-- spam. Generous headroom over the client caps. Drop-then-add for idempotent re-runs.
alter table public.bug_reports drop constraint if exists bug_reports_sane_sizes;
alter table public.bug_reports add constraint bug_reports_sane_sizes check (
    (description  is null or length(description)  <= 8000) and
    (player_name  is null or length(player_name)  <= 64)   and
    (game_version is null or length(game_version) <= 64)   and
    (platform     is null or length(platform)     <= 64)   and
    pg_column_size(telemetry) < 131072
);
