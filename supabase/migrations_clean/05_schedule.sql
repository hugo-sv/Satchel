-- Current final form — see note in 01_schema.sql.
--
-- Supabase runs pg_cron jobs as the `postgres` role, which bypasses RLS,
-- so neither distribute_income() nor prune_activity() need to be
-- callable by anyone else — neither has a grant to authenticated/anon
-- (see 02_functions.sql).

create extension if not exists pg_cron with schema extensions;

-- Hourly: if the bank has more money than active players, split it
-- evenly across them.
select cron.schedule(
  'distribute-income',
  '0 * * * *',
  $$select distribute_income()$$
);

-- Daily: delete activity rows older than 7 days.
select cron.schedule(
  'prune-activity',
  '0 3 * * *',
  $$select prune_activity()$$
);
