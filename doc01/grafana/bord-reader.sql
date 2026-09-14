-- One-time: a read-only Postgres role for grafana on doc01 to read the bord
-- Supabase project. Run as the project's `postgres` user - see README
-- "bord dashboard". Idempotent; re-run after any migration that adds tables
-- so the new ones get a read policy.
--
--   psql "$SUPABASE_URL" -v pw="$(cat ~/.secrets/bord-grafana-db-password)" -f bord-reader.sql

\set ON_ERROR_STOP on

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'grafana_ro') then
    create role grafana_ro login;
  end if;
end $$;

alter role grafana_ro with login password :'pw';

-- Session pooler + long dashboards: keep it from ever holding things up.
alter role grafana_ro set statement_timeout = '15s';
alter role grafana_ro set default_transaction_read_only = on;

grant usage on schema public to grafana_ro;
grant select on all tables in schema public to grafana_ro;
alter default privileges for role postgres in schema public
  grant select on tables to grafana_ro;

-- Every app table has RLS on and policies written for `authenticated` /
-- `anon`, so a plain grant sees zero rows. A read-everything policy per table
-- is the supported way through; BYPASSRLS needs superuser, which Supabase
-- does not hand out. auth.* is deliberately not covered - phone numbers stay
-- out of grafana.
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('drop policy if exists grafana_read on public.%I', t);
    execute format(
      'create policy grafana_read on public.%I for select to grafana_ro using (true)', t);
  end loop;
end $$;

select 'grafana_ro ok: ' || count(*) || ' tables readable'
  from pg_policies where policyname = 'grafana_read';
