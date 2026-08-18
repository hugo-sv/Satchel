-- Current schema, consolidated into its final form. The incremental
-- history of individual migrations that got the live project here has
-- been cleared — this is now the authoritative description of what
-- exists, though it's still not wired up to `supabase db push`; changes
-- are applied by hand via the SQL Editor and reflected back here.

-- Player: linked directly to Supabase auth user
-- Money is whole numbers only (no cents), everywhere in the schema.
create table player (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  money integer not null default 0,
  money_locked integer not null default 0,
  last_activity timestamptz not null default now(),
  is_bot boolean not null default false -- scripted account; not client-writable, flipped manually per bot
);

-- Item
create table item (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  illustration text, -- emoji glyph shown in place of a real image
  destruction_pot integer not null default 0,
  weight integer not null default 1 check (weight >= 0), -- lootbox drop weight; 0 = never drops
  is_base boolean not null default false, -- raw resource; Satchel groups these separately
  is_tool boolean not null default false -- reusable tool (consumed then returned by a recipe); Satchel groups these separately
);

-- Player_Item (inventory)
create table player_item (
  player_id uuid not null references player(id) on delete cascade,
  item_id uuid not null references item(id) on delete cascade,
  quantity integer not null default 0 check (quantity >= 0),
  for_sale_quantity integer not null default 0 check (for_sale_quantity >= 0 and for_sale_quantity <= quantity),
  primary key (player_id, item_id)
);

-- Offer (marketplace)
create table offer (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references player(id) on delete cascade,
  is_sell boolean not null, -- true = sell, false = buy
  price integer not null check (price >= 0),
  item_id uuid not null references item(id),
  -- >= 0, not > 0: accept_buy_offer/accept_sell_offer write a transient 0
  -- here before deleting the row when an offer is fulfilled in full.
  quantity integer not null check (quantity >= 0),
  created_at timestamptz not null default now()
);

-- Bank (single global row)
create table bank (
  id boolean primary key default true check (id), -- forces exactly one row
  money integer not null default 0
);

-- Recipe
create table recipe (
  id uuid primary key default gen_random_uuid(),
  name text not null
);

-- Recipe_Item (ingredients + outputs)
create table recipe_item (
  recipe_id uuid not null references recipe(id) on delete cascade,
  item_id uuid not null references item(id),
  quantity integer not null check (quantity > 0),
  is_output boolean not null, -- false = input, true = output
  primary key (recipe_id, item_id, is_output)
);

-- Activity log: one row per event, pruned after 7 days (see
-- 05_schedule.sql) since nothing ever reads past the last 50 rows.
-- `id` is bigint identity, not uuid — nothing references it as a
-- foreign key, and sequential bigints avoid the index bloat random
-- uuids cause on this, by far the highest-churn table. `detail` is
-- jsonb rather than fixed columns because craft (multiple items in/out)
-- and income (a bare amount) don't fit a fixed shape. A trade (buy or
-- sell) involves two parties, so it's logged as one 'trade' row with
-- both buyer_id and seller_id rather than one row per side — every
-- other event has a single actor and uses player_id instead.
create table activity (
  id bigint generated always as identity primary key,
  player_id uuid references player(id) on delete cascade,
  buyer_id uuid references player(id) on delete cascade,
  seller_id uuid references player(id) on delete cascade,
  type text not null check (type in (
    'craft', 'trade', 'income', 'sacrifice',
    'post_buy_offer', 'post_sell_offer', 'lootbox'
  )),
  detail jsonb not null default '{}',
  created_at timestamptz not null default now()
);
