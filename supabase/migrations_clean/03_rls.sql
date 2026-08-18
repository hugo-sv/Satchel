-- Current final form — see note in 01_schema.sql.
--
-- Final RLS shape: table-level policies plus grants for everything a
-- client can read or write directly (the player-update policy/trigger
-- that used to exist here was dropped — see below).
--
-- The SECURITY DEFINER functions in 02_functions.sql bypass RLS by
-- design (they're owned by the migration role). These policies govern
-- everything else: what a client can read or write directly through the
-- Supabase client library. Postgres checks table-level GRANTs before it
-- ever evaluates RLS policies, so both are needed together.

-- ============================================================
-- player
-- ============================================================
alter table player enable row level security;

-- Only the owner can read their own row directly (it includes money).
create policy player_select_own on player
  for select using (auth.uid() = id);

grant select on player to authenticated;

-- No update grant or policy: money/money_locked/last_activity are only
-- ever touched by the functions in 02_functions.sql, which bypass grants
-- as their owner. An earlier version had a client update policy plus a
-- trigger blocking money changes, but the trigger's `auth.role() =
-- 'service_role'` check could never be true for a SECURITY DEFINER
-- function called by a normal authenticated user — it silently blocked
-- every money-touching function. Since nothing needs direct client
-- updates to player, removing the grant entirely was simpler than fixing
-- the trigger's role check.

-- Public-safe view: only what other players are allowed to see about
-- you. Views run with their owner's privileges by default, so this reads
-- past the owner-only policy above without exposing money/money_locked.
create view player_public as
  select id, username, last_activity from player;
grant select on player_public to anon, authenticated;

-- ============================================================
-- item / recipe / recipe_item — public read-only catalog data
-- ============================================================
alter table item enable row level security;
alter table recipe enable row level security;
alter table recipe_item enable row level security;

create policy item_select_all on item for select using (true);
create policy recipe_select_all on recipe for select using (true);
create policy recipe_item_select_all on recipe_item for select using (true);

-- Column-level grant, not the whole table: destruction_pot must stay
-- hidden from clients (RLS only controls row visibility, not column
-- visibility) so nobody can scout the best sacrifice payout in advance.
-- cost is a static, purely-derived reference value, safe to expose.
grant select (id, name, illustration, weight, is_base, is_tool, cost) on item to anon, authenticated;
grant select on recipe to anon, authenticated;
grant select on recipe_item to anon, authenticated;

-- ============================================================
-- offer — public read; no client insert/update/delete.
-- Posting/accepting/cancelling all go through the RPC functions, which
-- enforce the listing fee and balance checks that a raw insert or delete
-- would skip entirely.
-- ============================================================
alter table offer enable row level security;

create policy offer_select_all on offer for select using (true);
grant select on offer to anon, authenticated;

-- ============================================================
-- player_item — owner sees everything, others see only for-sale stock
-- ============================================================
alter table player_item enable row level security;

create policy player_item_select on player_item
  for select using (player_id = auth.uid() or for_sale_quantity > 0);

grant select on player_item to authenticated;

-- ============================================================
-- bank — no client access at all, in either direction
-- ============================================================
alter table bank enable row level security;

-- ============================================================
-- activity — read-your-own-events only; written only by the RPC
-- functions. Single-actor events (craft, destroy, lootbox, posting an
-- offer, income) use player_id; a 'trade' has two parties and uses
-- buyer_id/seller_id instead, so either side can read it.
-- ============================================================
alter table activity enable row level security;

create policy activity_select_own on activity
  for select using (
    player_id = auth.uid() or buyer_id = auth.uid() or seller_id = auth.uid()
  );

grant select on activity to authenticated;
