"""If it has enough money, buy all items at a given price, and sell them all at a higher price (✦ less than the next best offer)"""

import random


def decide(state: dict) -> list:
    money = state["money"]["money"]

    own_sell_qty_at_price = {}
    for o in state["own_offers"]:
        if o["is_sell"]:
            key = (o["item_id"], o["price"])
            own_sell_qty_at_price[key] = own_sell_qty_at_price.get(key, 0) + o["quantity"]

    candidates = []
    for item_id, raw_tiers in state["sell_tiers"].items():
        # Strip out this bot's own listed quantity at each price tier —
        # never buy its own offers back.
        tiers = []
        for tier in raw_tiers:
            external_qty = tier["quantity"] - own_sell_qty_at_price.get((item_id, tier["price"]), 0)
            if external_qty > 0:
                tiers.append({**tier, "quantity": external_qty})

        if not tiers:
            continue
        best = tiers[0]
        cost = best["price"] * best["quantity"]
        if cost <= money:
            candidates.append((item_id, tiers, cost))

    if not candidates:
        return []

    item_id, tiers, cost = random.choice(candidates)
    best = tiers[0]
    qty = best["quantity"]

    # Undercut what was the next-cheapest tier before this purchase; with
    # no second tier to reference, price to cover cost plus a margin.
    next_tier = tiers[1] if len(tiers) > 1 else None
    price = next_tier["price"] - 1 if next_tier else cost + 20

    return [
        {"rpc": "accept_sell_offer", "args": {"item_id": item_id, "qty": qty}},
        {"rpc": "post_sell_offer", "args": {"item_id": item_id, "qty": qty, "price": max(price, 0)}},
    ]
