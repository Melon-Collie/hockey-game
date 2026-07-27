-- CI-ONLY role bootstrap. NOT a migration — never run against the hosted
-- project, which already owns these roles (they are part of every Supabase
-- database, created before any of our DDL runs).
--
-- The migrations grant to `anon`, so replaying them against a vanilla Postgres
-- container — which is how CI proves they still build from scratch — fails at
-- the first GRANT without these. Only the roles our DDL actually names are
-- created; this is a stand-in for Supabase's bootstrap, not a copy of it.

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon nologin noinherit;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin noinherit;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role nologin noinherit bypassrls;
    end if;
end
$$;

grant usage on schema public to anon, authenticated, service_role;
