"""1. Check which recipes can be crafted (inventory, cancellable own
offers, or the market). 2. Randomly pick one, prioritizing any with a
non-tool output that has no offer at all. 3. Buy/cancel what's needed
and craft it. 4. List any non-base item in the satchel with no offer at
cost*20. 5. List any non-base item with an offer at (best offer - 1),
unless that's below cost*10. Always keeps at least one of any tool.
6. If nothing was craftable, scry with at most 33% of its money."""

import random

SCRY_RATIO_NUM = 33
SCRY_RATIO_DEN = 100
LOOTBOX_UNIT_PRICE = 10
NO_OFFER_COST_MULTIPLIER = 20
MIN_UNDERCUT_COST_MULTIPLIER = 10


def _scry(money: int) -> list:
    to_spend = (money * SCRY_RATIO_NUM) // SCRY_RATIO_DEN
    qty = to_spend // LOOTBOX_UNIT_PRICE
    return [{"rpc": "buy_lootbox", "args": {"qty": qty}}] if qty > 0 else []


def decide(state: dict) -> list:
    money = state["money"]["money"]
    market = state["market"]
    items_by_id = {item["id"]: item for item in state["items"]}
    inventory = {row["item_id"]: row for row in state["inventory"]}

    # This bot's own open sell offers, grouped by item — a shortfall can
    # be covered by cancelling one of these instead of buying fresh.
    own_sell_offers = {}
    for o in state["own_offers"]:
        if o["is_sell"]:
            own_sell_offers.setdefault(o["item_id"], []).append(o)

    # Step 1: which recipes are craftable right now.
    craftable = []
    for recipe in state["recipes"]:
        needed = recipe["inputs"] + recipe["tools"]

        total_cost = 0
        actions = []
        affordable = True
        for i in needed:
            row = inventory.get(i["item_id"])
            owned_unlisted = (row["quantity"] - row["for_sale_quantity"]) if row else 0
            shortfall = i["quantity"] - owned_unlisted
            if shortfall <= 0:
                continue

            # Free up its own listed stock first — cancelling a whole
            # offer at a time (no partial cancel), even if that frees
            # more than strictly needed.
            for offer in own_sell_offers.get(i["item_id"], []):
                if shortfall <= 0:
                    break
                actions.append({"rpc": "cancel_offer", "args": {"offer_id": offer["id"]}})
                shortfall -= offer["quantity"]
            if shortfall <= 0:
                continue

            offer = market.get(i["item_id"], {}).get("best_sell")
            if not offer or offer["quantity"] < shortfall:
                affordable = False
                break
            total_cost += offer["price"] * shortfall
            actions.append({"rpc": "accept_sell_offer", "args": {"item_id": i["item_id"], "qty": shortfall}})

        if not (affordable and total_cost <= money):
            continue

        has_unpriced_output = any(
            not market.get(o["item_id"], {}).get("best_sell") for o in recipe["outputs"]
        )
        craftable.append((recipe, actions, has_unpriced_output))

    if not craftable:
        return _scry(money)

    # Step 2: random pick, prioritizing a recipe with an unpriced
    # non-tool output.
    unpriced = [c for c in craftable if c[2]]
    recipe, actions, _ = random.choice(unpriced) if unpriced else random.choice(craftable)

    # Step 3.
    actions = actions + [{"rpc": "craft", "args": {"recipe_id": recipe["recipe_id"], "qty": 1}}]

    # Steps 4 & 5: sweep the whole satchel, not just this recipe's
    # output — list any non-base item that isn't already fully listed,
    # always holding back at least one unit of any tool.
    for row in state["inventory"]:
        item = items_by_id.get(row["item_id"])
        if not item or item["is_base"]:
            continue

        available = row["quantity"] - row["for_sale_quantity"]
        if item["is_tool"]:
            available -= 1
        if available <= 0:
            continue

        cost = item["cost"]
        best_sell = market.get(row["item_id"], {}).get("best_sell")

        if not best_sell:
            price = round(cost * NO_OFFER_COST_MULTIPLIER)
        else:
            price = best_sell["price"] - 1
            if price < cost * MIN_UNDERCUT_COST_MULTIPLIER:
                continue

        actions.append({"rpc": "post_sell_offer", "args": {"item_id": row["item_id"], "qty": available, "price": max(price, 0)}})

    return actions
