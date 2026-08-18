-- Current final form — see note in 01_schema.sql.
--
-- Seeds the alchemy crafting tree from CraftingTree/*.csv: 15 items,
-- 7 recipes, 33 recipe_item links.
--
-- CSV "IsBaseItem" maps to both is_base (shown differently in the
-- inventory) and lootbox weight: base/raw materials get weight 1
-- (droppable) and is_base true, crafted intermediates/final goods get
-- weight 0 (only obtainable by crafting — see 02_functions.sql) and
-- is_base false. destruction_pot is left at its default (0) for
-- everything since the CSVs don't specify one.
--
-- Mortar & Pestle and Alembic are tools: each shows up as both an input
-- row and an output row of the same recipe (consumed then returned) —
-- recipe_item's primary key includes is_output, so that's just two
-- distinct rows, not a conflict.
--
-- `cost`: base-resource units to make one, recursively through the
-- recipes below (tools excluded, divided by the recipe's total output
-- quantity) — see 20260819030000_item_cost.sql for the per-item math.

insert into item (name, weight, is_base, illustration, cost) values
  ('Spring Water', 1, true, '🪣', 1),
  ('Moonleaf', 1, true, '🌙', 1),
  ('Sunroot', 1, true, '🌱', 1),
  ('Quartz Dust', 1, true, '✨', 1),
  ('Sulfur', 1, true, '🟡', 1),
  ('Glass Sand', 1, true, '⏳', 1),
  ('Charcoal', 1, true, '⬛', 1),
  ('Mortar & Pestle', 0, false, '🥣', 13),
  ('Alembic', 0, false, '⚗️', 17),
  ('Crushed Herb Powder', 0, false, '🌿', 1.333333),
  ('Purified Water', 0, false, '💧', 2),
  ('Quartz Residue', 0, false, '⚪', 2),
  ('Herbal Extract', 0, false, '🫙', 9.333333),
  ('Catalyst Powder', 0, false, '🧂', 4),
  ('Philosopher''s Stone', 0, false, '💎', 21.333333);

insert into recipe (name) values
  ('Mortar & Pestle Crafting'),
  ('Alembic Crafting'),
  ('Grinding'),
  ('Purification'),
  ('Catalyzing'),
  ('Distillation'),
  ('Transmutation');

insert into recipe_item (recipe_id, item_id, quantity, is_output)
select r.id, i.id, v.quantity, v.is_output
from (values
  ('Mortar & Pestle Crafting', 'Quartz Dust', 6, false),
  ('Mortar & Pestle Crafting', 'Sunroot', 4, false),
  ('Mortar & Pestle Crafting', 'Charcoal', 3, false),
  ('Mortar & Pestle Crafting', 'Mortar & Pestle', 1, true),

  ('Alembic Crafting', 'Glass Sand', 8, false),
  ('Alembic Crafting', 'Sulfur', 5, false),
  ('Alembic Crafting', 'Charcoal', 4, false),
  ('Alembic Crafting', 'Alembic', 1, true),

  ('Grinding', 'Moonleaf', 5, false),
  ('Grinding', 'Sunroot', 3, false),
  ('Grinding', 'Mortar & Pestle', 1, false),
  ('Grinding', 'Mortar & Pestle', 1, true),
  ('Grinding', 'Crushed Herb Powder', 6, true),

  ('Purification', 'Spring Water', 5, false),
  ('Purification', 'Quartz Dust', 3, false),
  ('Purification', 'Alembic', 1, false),
  ('Purification', 'Alembic', 1, true),
  ('Purification', 'Purified Water', 2, true),
  ('Purification', 'Quartz Residue', 2, true),

  ('Catalyzing', 'Sulfur', 5, false),
  ('Catalyzing', 'Charcoal', 3, false),
  ('Catalyzing', 'Catalyst Powder', 2, true),

  ('Distillation', 'Crushed Herb Powder', 4, false),
  ('Distillation', 'Purified Water', 2, false),
  ('Distillation', 'Alembic', 1, false),
  ('Distillation', 'Alembic', 1, true),
  ('Distillation', 'Herbal Extract', 1, true),

  ('Transmutation', 'Herbal Extract', 1, false),
  ('Transmutation', 'Catalyst Powder', 2, false),
  ('Transmutation', 'Quartz Residue', 2, false),
  ('Transmutation', 'Mortar & Pestle', 1, false),
  ('Transmutation', 'Mortar & Pestle', 1, true),
  ('Transmutation', 'Philosopher''s Stone', 1, true)
) as v(recipe_name, item_name, quantity, is_output)
join recipe r on r.name = v.recipe_name
join item i on i.name = v.item_name;
