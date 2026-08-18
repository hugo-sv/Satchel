"""Buy one of every item it doesn't already have, for as long as there's an affordable offer and money left, then sacrifice a random item it has."""

import random


def decide(state: dict) -> list:
    inventory = state["inventory"]
    market = state["market"]
    money = state["money"]["money"]

    owned_ids = {row["item_id"] for row in inventory if row["quantity"] > 0}
    sacrificeable_ids = {row["item_id"] for row in inventory if row["quantity"] - row["for_sale_quantity"] > 0}

    actions = []
    for item in state["items"]:
        item_id = item["id"]
        if item_id in owned_ids:
            continue
        offer = market.get(item_id, {}).get("best_sell")
        if not offer or offer["price"] > money:
            continue

        actions.append({"rpc": "accept_sell_offer", "args": {"item_id": item_id, "qty": 1}})
        money -= offer["price"]
        sacrificeable_ids.add(item_id)

    if sacrificeable_ids:
        target_id = random.choice(list(sacrificeable_ids))
        actions.append({"rpc": "sacrifice", "args": {"item_id": target_id}})

    return actions
