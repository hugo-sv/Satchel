"""If it has enough money, buy all items at a given price, and sell them all at a higher price (✦ less than the next best offer)"""

import random


def decide(state: dict) -> list:
    money = state["money"]["money"]

    candidates = []
    for item_id, tiers in state["sell_tiers"].items():
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
