-- Current final form — see note in 01_schema.sql.
--
-- Final form of every trusted operation (fee, activity logging, the
-- pg-safeupdate fix in sacrifice_item, craft's output tracking, integer
-- money, and everything else worked out along the way). Each is
-- SECURITY DEFINER so it can bypass per-table RLS while still enforcing
-- its own rules — the "must go through a trusted operation" path for
-- anything touching money or item quantities on both sides of a
-- transfer.
--
-- Shared design rule: `for_sale_quantity` marks inventory as committed to
-- a sell offer. Operations that are NOT accepting that sell offer (buying
-- into someone's buy offer, crafting, sacrificing) only draw from the
-- *unlisted* portion (quantity - for_sale_quantity).
--
-- Money is integer everywhere (no cents). The 5% listing fee rounds UP
-- (ceil), so it's never silently 0 on a cheap offer.

-- ============================================================
-- accept_buy_offer/accept_sell_offer take an item (not a single offer)
-- and fill sequentially across every offer tied at the best price
-- (oldest first) until p_qty is met. Deliberately does NOT spill into
-- worse prices — all-or-nothing at the best price shown to the player,
-- same as the rest of these functions. A request can span offers from
-- different counterparties, so one 'trade' activity row is logged per
-- fill (per offer consumed), carrying both buyer_id and seller_id.
create or replace function accept_buy_offer(p_item_id uuid, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller_id uuid := auth.uid();
  v_best_price integer;
  v_remaining integer := p_qty;
  r record;
  v_fill integer;
  v_buyer_id uuid;
begin
  if v_seller_id is null then
    raise exception 'authentication required';
  end if;
  if p_qty <= 0 then
    raise exception 'quantity must be positive';
  end if;

  select max(price) into v_best_price
    from offer
    where item_id = p_item_id and is_sell = false;

  if v_best_price is null then
    raise exception 'no buy offers for this item';
  end if;

  update player_item
    set quantity = quantity - p_qty
    where player_id = v_seller_id and item_id = p_item_id
      and quantity - for_sale_quantity >= p_qty;

  if not found then
    raise exception 'insufficient item quantity';
  end if;

  for r in
    select id, player_id, quantity from offer
      where item_id = p_item_id and is_sell = false and price = v_best_price
      order by created_at asc
      for update
  loop
    exit when v_remaining = 0;

    v_fill := least(v_remaining, r.quantity);
    v_buyer_id := r.player_id;

    update offer set quantity = quantity - v_fill where id = r.id;
    delete from offer where id = r.id and quantity = 0;

    insert into player_item (player_id, item_id, quantity)
      values (v_buyer_id, p_item_id, v_fill)
      on conflict (player_id, item_id)
      do update set quantity = player_item.quantity + excluded.quantity;

    update player set money_locked = money_locked - (v_fill * v_best_price) where id = v_buyer_id;
    update player set money = money + (v_fill * v_best_price) where id = v_seller_id;

    insert into activity (type, detail, buyer_id, seller_id) values
      ('trade', jsonb_build_object('item_id', p_item_id, 'quantity', v_fill, 'price', v_best_price, 'total', v_fill * v_best_price, 'offer_id', r.id), v_buyer_id, v_seller_id);

    v_remaining := v_remaining - v_fill;
  end loop;

  if v_remaining > 0 then
    raise exception 'insufficient quantity available at the best price';
  end if;

  update player set last_activity = now() where id = v_seller_id;
end;
$$;

-- ============================================================
create or replace function accept_sell_offer(p_item_id uuid, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_buyer_id uuid := auth.uid();
  v_best_price integer;
  v_total_cost integer;
  v_remaining integer := p_qty;
  r record;
  v_fill integer;
  v_seller_id uuid;
begin
  if v_buyer_id is null then
    raise exception 'authentication required';
  end if;
  if p_qty <= 0 then
    raise exception 'quantity must be positive';
  end if;

  select min(price) into v_best_price
    from offer
    where item_id = p_item_id and is_sell = true;

  if v_best_price is null then
    raise exception 'no sell offers for this item';
  end if;

  v_total_cost := p_qty * v_best_price;

  update player
    set money = money - v_total_cost
    where id = v_buyer_id and money >= v_total_cost;

  if not found then
    raise exception 'insufficient funds';
  end if;

  for r in
    select id, player_id, quantity from offer
      where item_id = p_item_id and is_sell = true and price = v_best_price
      order by created_at asc
      for update
  loop
    exit when v_remaining = 0;

    v_fill := least(v_remaining, r.quantity);
    v_seller_id := r.player_id;

    update offer set quantity = quantity - v_fill where id = r.id;
    delete from offer where id = r.id and quantity = 0;

    update player_item
      set quantity = quantity - v_fill,
          for_sale_quantity = for_sale_quantity - v_fill
      where player_id = v_seller_id and item_id = p_item_id;

    insert into player_item (player_id, item_id, quantity)
      values (v_buyer_id, p_item_id, v_fill)
      on conflict (player_id, item_id)
      do update set quantity = player_item.quantity + excluded.quantity;

    update player set money = money + (v_fill * v_best_price) where id = v_seller_id;

    insert into activity (type, detail, buyer_id, seller_id) values
      ('trade', jsonb_build_object('item_id', p_item_id, 'quantity', v_fill, 'price', v_best_price, 'total', v_fill * v_best_price, 'offer_id', r.id), v_buyer_id, v_seller_id);

    v_remaining := v_remaining - v_fill;
  end loop;

  if v_remaining > 0 then
    raise exception 'insufficient quantity available at the best price';
  end if;

  update player set last_activity = now() where id = v_buyer_id;
end;
$$;

-- ============================================================
-- Posting a buy offer matches immediately against any sell offers
-- priced at or below the posted price — cheapest first, oldest first
-- within a tie. The matched portion is a free trade at each matched
-- offer's own (possibly cheaper) price, exactly like clicking "Buy";
-- only the leftover quantity (if any) becomes an actual resting offer,
-- and only that leftover pays the 5% listing fee. Fully matched means
-- no offer row is created and the function returns null. All-or-nothing
-- like everything else here: insufficient funds at any point rolls the
-- whole call back. post_sell_offer below does the symmetric thing for
-- sell offers against existing buy offers.
create or replace function post_buy_offer(p_item_id uuid, p_qty integer, p_price integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_remaining integer := p_qty;
  r record;
  v_fill integer;
  v_seller_id uuid;
  v_fill_cost integer;
  v_offer_id uuid;
  v_total integer;
  v_fee integer;
begin
  if v_player_id is null then
    raise exception 'authentication required';
  end if;
  if p_qty <= 0 then
    raise exception 'quantity must be positive';
  end if;
  if p_price < 0 then
    raise exception 'price must be non-negative';
  end if;

  for r in
    select id, player_id, price, quantity from offer
      where item_id = p_item_id and is_sell = true and price <= p_price
      order by price asc, created_at asc
      for update
  loop
    exit when v_remaining = 0;

    v_fill := least(v_remaining, r.quantity);
    v_seller_id := r.player_id;
    v_fill_cost := v_fill * r.price;

    update player
      set money = money - v_fill_cost
      where id = v_player_id and money >= v_fill_cost;

    if not found then
      raise exception 'insufficient funds';
    end if;

    update offer set quantity = quantity - v_fill where id = r.id;
    delete from offer where id = r.id and quantity = 0;

    update player_item
      set quantity = quantity - v_fill,
          for_sale_quantity = for_sale_quantity - v_fill
      where player_id = v_seller_id and item_id = p_item_id;

    insert into player_item (player_id, item_id, quantity)
      values (v_player_id, p_item_id, v_fill)
      on conflict (player_id, item_id)
      do update set quantity = player_item.quantity + excluded.quantity;

    update player set money = money + v_fill_cost where id = v_seller_id;

    insert into activity (type, detail, buyer_id, seller_id) values
      ('trade', jsonb_build_object('item_id', p_item_id, 'quantity', v_fill, 'price', r.price, 'total', v_fill_cost, 'offer_id', r.id), v_player_id, v_seller_id);

    v_remaining := v_remaining - v_fill;
  end loop;

  update player set last_activity = now() where id = v_player_id;

  if v_remaining = 0 then
    return null;
  end if;

  v_total := v_remaining * p_price;
  v_fee := ceil(v_total * 0.05)::integer;

  update player
    set money = money - v_total - v_fee,
        money_locked = money_locked + v_total
    where id = v_player_id and money >= v_total + v_fee;

  if not found then
    raise exception 'insufficient funds';
  end if;

  update bank set money = money + v_fee where id = true;

  insert into offer (player_id, is_sell, price, item_id, quantity)
    values (v_player_id, false, p_price, p_item_id, v_remaining)
    returning id into v_offer_id;

  insert into activity (player_id, type, detail)
    values (v_player_id, 'post_buy_offer', jsonb_build_object('item_id', p_item_id, 'quantity', v_remaining, 'price', p_price, 'offer_id', v_offer_id, 'fee', v_fee));

  return v_offer_id;
end;
$$;

-- ============================================================
-- Symmetric counterpart to post_buy_offer above: posting a sell offer
-- priced at or below existing buy offers matches immediately against
-- them — highest price first (best for the seller), oldest first
-- within a tie. Matched portion is a free trade at each matched offer's
-- own (possibly higher) price; only the leftover becomes a resting sell
-- offer and pays the 5% fee. The seller-side item check happens per
-- fill (quantity - for_sale_quantity >= v_fill) rather than once
-- upfront — since for_sale_quantity never changes during matching, this
-- naturally enforces the running total against the original unlisted
-- capacity.
create or replace function post_sell_offer(p_item_id uuid, p_qty integer, p_price integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_remaining integer := p_qty;
  r record;
  v_fill integer;
  v_buyer_id uuid;
  v_fill_cost integer;
  v_offer_id uuid;
  v_fee integer;
begin
  if v_player_id is null then
    raise exception 'authentication required';
  end if;
  if p_qty <= 0 then
    raise exception 'quantity must be positive';
  end if;
  if p_price < 0 then
    raise exception 'price must be non-negative';
  end if;

  for r in
    select id, player_id, price, quantity from offer
      where item_id = p_item_id and is_sell = false and price >= p_price
      order by price desc, created_at asc
      for update
  loop
    exit when v_remaining = 0;

    v_fill := least(v_remaining, r.quantity);
    v_buyer_id := r.player_id;
    v_fill_cost := v_fill * r.price;

    update player_item
      set quantity = quantity - v_fill
      where player_id = v_player_id and item_id = p_item_id
        and quantity - for_sale_quantity >= v_fill;

    if not found then
      raise exception 'insufficient item quantity';
    end if;

    update offer set quantity = quantity - v_fill where id = r.id;
    delete from offer where id = r.id and quantity = 0;

    insert into player_item (player_id, item_id, quantity)
      values (v_buyer_id, p_item_id, v_fill)
      on conflict (player_id, item_id)
      do update set quantity = player_item.quantity + excluded.quantity;

    update player set money_locked = money_locked - v_fill_cost where id = v_buyer_id;
    update player set money = money + v_fill_cost where id = v_player_id;

    insert into activity (type, detail, buyer_id, seller_id) values
      ('trade', jsonb_build_object('item_id', p_item_id, 'quantity', v_fill, 'price', r.price, 'total', v_fill_cost, 'offer_id', r.id), v_buyer_id, v_player_id);

    v_remaining := v_remaining - v_fill;
  end loop;

  update player set last_activity = now() where id = v_player_id;

  if v_remaining = 0 then
    return null;
  end if;

  update player_item
    set for_sale_quantity = for_sale_quantity + v_remaining
    where player_id = v_player_id and item_id = p_item_id
      and quantity - for_sale_quantity >= v_remaining;

  if not found then
    raise exception 'insufficient item quantity';
  end if;

  v_fee := ceil(v_remaining * p_price * 0.05)::integer;

  update player
    set money = money - v_fee
    where id = v_player_id and money >= v_fee;

  if not found then
    raise exception 'insufficient funds for listing fee';
  end if;

  update bank set money = money + v_fee where id = true;

  insert into offer (player_id, is_sell, price, item_id, quantity)
    values (v_player_id, true, p_price, p_item_id, v_remaining)
    returning id into v_offer_id;

  insert into activity (player_id, type, detail)
    values (v_player_id, 'post_sell_offer', jsonb_build_object('item_id', p_item_id, 'quantity', v_remaining, 'price', p_price, 'offer_id', v_offer_id, 'fee', v_fee));

  return v_offer_id;
end;
$$;

-- ============================================================
create or replace function cancel_offer(p_offer_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_is_sell boolean;
  v_item_id uuid;
  v_price integer;
  v_qty integer;
begin
  if v_player_id is null then
    raise exception 'authentication required';
  end if;

  delete from offer
    where id = p_offer_id and player_id = v_player_id
    returning is_sell, item_id, price, quantity
    into v_is_sell, v_item_id, v_price, v_qty;

  if not found then
    raise exception 'offer not found or not yours';
  end if;

  if v_is_sell then
    update player_item
      set for_sale_quantity = for_sale_quantity - v_qty
      where player_id = v_player_id and item_id = v_item_id;
  else
    update player
      set money = money + (v_qty * v_price),
          money_locked = money_locked - (v_qty * v_price)
      where id = v_player_id;
  end if;
end;
$$;

-- ============================================================
create or replace function craft(p_recipe_id uuid, p_qty integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  r record;
  v_outputs jsonb := '[]'::jsonb;
begin
  if v_player_id is null then
    raise exception 'authentication required';
  end if;
  if p_qty <= 0 then
    raise exception 'quantity must be positive';
  end if;

  if not exists (select 1 from recipe_item where recipe_id = p_recipe_id) then
    raise exception 'recipe not found or has no items';
  end if;

  -- Consume inputs before producing outputs, in a fixed item order, so a
  -- mid-recipe shortfall rolls back everything already deducted.
  for r in
    select item_id, quantity from recipe_item
      where recipe_id = p_recipe_id and is_output = false
      order by item_id
  loop
    update player_item
      set quantity = quantity - (r.quantity * p_qty)
      where player_id = v_player_id and item_id = r.item_id
        and quantity - for_sale_quantity >= r.quantity * p_qty;

    if not found then
      raise exception 'insufficient quantity of item % for this recipe', r.item_id;
    end if;
  end loop;

  for r in
    select item_id, quantity from recipe_item
      where recipe_id = p_recipe_id and is_output = true
      order by item_id
  loop
    insert into player_item (player_id, item_id, quantity)
      values (v_player_id, r.item_id, r.quantity * p_qty)
      on conflict (player_id, item_id)
      do update set quantity = player_item.quantity + excluded.quantity;

    -- Tools (consumed then returned by this same recipe) are still
    -- credited above, but skipped here so the Ledger doesn't show
    -- borrowing a tool as if it were a genuine yield.
    if not exists (
      select 1 from recipe_item ri
        where ri.recipe_id = p_recipe_id and ri.item_id = r.item_id and ri.is_output = false
    ) then
      v_outputs := v_outputs || jsonb_build_object('item_id', r.item_id, 'quantity', r.quantity * p_qty);
    end if;
  end loop;

  update player set last_activity = now() where id = v_player_id;

  insert into activity (player_id, type, detail)
    values (v_player_id, 'craft', jsonb_build_object('recipe_id', p_recipe_id, 'quantity', p_qty, 'outputs', v_outputs));
end;
$$;

-- ============================================================
-- Sacrifice: always exactly one unit (no batch quantity — that alone
-- means the +1 bump to every other item's pot is always proportional to
-- what was actually sacrificed, closing off the call-splitting exploit
-- an earlier, batched version of this had). Payout is simply the target
-- item's destruction_pot. Recency is handled by the pot itself, not a
-- timer: sacrificing an item resets it to 0, then every item (including
-- it) gets +1 — so a just-sacrificed item pays out little until other
-- sacrifices build its pot back up.
create or replace function sacrifice_item(p_item_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_payout integer;
begin
  if v_player_id is null then
    raise exception 'authentication required';
  end if;

  update player_item
    set quantity = quantity - 1
    where player_id = v_player_id and item_id = p_item_id
      and quantity - for_sale_quantity >= 1;

  if not found then
    raise exception 'insufficient item quantity';
  end if;

  select destruction_pot into v_payout from item where id = p_item_id for update;

  update item set destruction_pot = 0 where id = p_item_id;
  update item set destruction_pot = destruction_pot + 1 where true;

  -- Bank money is allowed to go negative — no funds guard here.
  update bank set money = money - v_payout where id = true;

  update player
    set money = money + v_payout,
        last_activity = now()
    where id = v_player_id;

  insert into activity (player_id, type, detail)
    values (v_player_id, 'sacrifice', jsonb_build_object('item_id', p_item_id, 'payout', v_payout));

  return v_payout;
end;
$$;

-- ============================================================
-- Takes a batch quantity so a player can scry multiple times in one
-- call. Charges the full batch up front, then draws each item
-- independently (with replacement — duplicates expected). Logs one
-- activity row for the whole batch listing every item drawn.
create or replace function buy_lootbox(p_qty integer default 1)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player_id uuid := auth.uid();
  v_unit_price integer := 10;
  v_total integer;
  v_item_id uuid;
  v_items jsonb := '[]'::jsonb;
  i integer;
begin
  if v_player_id is null then
    raise exception 'authentication required';
  end if;
  if p_qty <= 0 then
    raise exception 'quantity must be positive';
  end if;

  v_total := v_unit_price * p_qty;

  update player
    set money = money - v_total,
        last_activity = now()
    where id = v_player_id and money >= v_total;

  if not found then
    raise exception 'insufficient funds';
  end if;

  update bank set money = money + v_total where id = true;

  for i in 1..p_qty loop
    -- Weighted pick: each eligible item gets a random key of
    -- random()^(1/weight); the item with the largest key wins. This
    -- reproduces "probability proportional to weight" in one ORDER BY,
    -- no cumulative-sum bookkeeping needed (Efraimidis-Spirakis method).
    select id into v_item_id
      from item
      where weight > 0
      order by power(random(), 1.0 / weight) desc
      limit 1;

    if v_item_id is null then
      raise exception 'no items available';
    end if;

    insert into player_item (player_id, item_id, quantity)
      values (v_player_id, v_item_id, 1)
      on conflict (player_id, item_id)
      do update set quantity = player_item.quantity + excluded.quantity;

    v_items := v_items || to_jsonb(v_item_id);
  end loop;

  insert into activity (player_id, type, detail)
    values (v_player_id, 'lootbox', jsonb_build_object('qty', p_qty, 'total', v_total, 'items', v_items));

  return v_items;
end;
$$;

-- ============================================================
-- distribute_income: hourly job (via pg_cron, not called from the
-- client — see 05_schedule.sql). If the bank has more money than there
-- are active players (active = last_activity within the last 7 days,
-- or a bot — bots always count as active regardless of last_activity),
-- split the whole bank balance evenly across them.
-- ============================================================
create or replace function distribute_income()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_bank_money integer;
  v_share integer;
begin
  select count(*) into v_count
    from player
    where last_activity >= now() - interval '7 days' or is_bot;

  if v_count = 0 then
    return;
  end if;

  select money into v_bank_money from bank where id = true;

  if v_bank_money <= v_count then
    return;
  end if;

  -- Integer division truncates, so the remainder of the split
  -- automatically stays in the bank rather than being created or lost.
  v_share := v_bank_money / v_count;

  update player
    set money = money + v_share
    where last_activity >= now() - interval '7 days' or is_bot;

  update bank set money = money - v_share * v_count where id = true;

  insert into activity (player_id, type, detail)
    select id, 'income', jsonb_build_object('amount', v_share)
    from player
    where last_activity >= now() - interval '7 days' or is_bot;
end;
$$;

-- ============================================================
-- prune_activity: daily job (via pg_cron — see 05_schedule.sql). Nothing
-- ever reads activity beyond the last 50 rows (the Ledger), so old rows
-- are pure dead weight; this bounds table growth regardless of volume.
-- ============================================================
create or replace function prune_activity()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from activity where created_at < now() - interval '7 days';
end;
$$;

-- ============================================================
-- Grants: authenticated players can call every player-facing operation.
-- distribute_income and prune_activity get none — both are cron-only,
-- invoked as their owner.
-- ============================================================
revoke all on function accept_buy_offer(uuid, integer) from public;
grant execute on function accept_buy_offer(uuid, integer) to authenticated;

revoke all on function accept_sell_offer(uuid, integer) from public;
grant execute on function accept_sell_offer(uuid, integer) to authenticated;

revoke all on function post_buy_offer(uuid, integer, integer) from public;
grant execute on function post_buy_offer(uuid, integer, integer) to authenticated;

revoke all on function post_sell_offer(uuid, integer, integer) from public;
grant execute on function post_sell_offer(uuid, integer, integer) to authenticated;

revoke all on function cancel_offer(uuid) from public;
grant execute on function cancel_offer(uuid) to authenticated;

revoke all on function craft(uuid, integer) from public;
grant execute on function craft(uuid, integer) to authenticated;

revoke all on function sacrifice_item(uuid) from public;
grant execute on function sacrifice_item(uuid) to authenticated;

revoke all on function buy_lootbox(integer) from public;
grant execute on function buy_lootbox(integer) to authenticated;

revoke all on function distribute_income() from public;
revoke all on function prune_activity() from public;
