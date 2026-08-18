-- Current final form — see note in 01_schema.sql.
--
-- Creates the matching `player` row whenever someone signs up via
-- Supabase Auth. `username` is expected to be passed as signup metadata
-- (supabase.auth.signUp({ ..., options: { data: { username } } })), landing
-- in auth.users.raw_user_meta_data. There is no other path to set it, so a
-- signup without it fails outright rather than leaving a broken player row.
-- New players start with 333 money.

create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_username text := new.raw_user_meta_data->>'username';
begin
  if v_username is null or length(trim(v_username)) = 0 then
    raise exception 'username is required to create a player';
  end if;

  insert into player (id, username, money) values (new.id, v_username, 333);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();
