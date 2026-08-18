"""Chose a recipe it can buy the ingredients, buy them, craft and sell the output 1✦ less than the best offer. If there are no offers, sells for the total spent + 20✦"""

import random


def decide(state: dict) -> list:
    money = state["money"]["money"]
    market = state["market"]
    inventory = {row["item_id"]: row["quantity"] - row["for_sale_quantity"] for row in state["inventory"]}

    eligible = []
    for recipe in state["recipes"]:
        if not recipe["outputs"]:
            continue
        # Tools are borrowed then returned by the craft itself — must
        # already be owned, never bought fresh for a single use.
        if any(inventory.get(t["item_id"], 0) < t["quantity"] for t in recipe["tools"]):
            continue

        total_cost = 0
        buys = []
        affordable = True
        for i in recipe["inputs"]:
            offer = market.get(i["item_id"], {}).get("best_sell")
            if not offer or offer["quantity"] < i["quantity"]:
                affordable = False
                break
            total_cost += offer["price"] * i["quantity"]
            buys.append({"rpc": "accept_sell_offer", "args": {"item_id": i["item_id"], "qty": i["quantity"]}})

        if affordable and total_cost <= money:
            eligible.append((recipe, buys, total_cost))

    if not eligible:
        return []

    recipe, buys, total_cost = random.choice(eligible)
    output = recipe["outputs"][0]
    output_offer = market.get(output["item_id"], {}).get("best_sell")
    price = output_offer["price"] - 1 if output_offer else total_cost + 20

    return buys + [
        {"rpc": "craft", "args": {"recipe_id": recipe["recipe_id"], "qty": 1}},
        {"rpc": "post_sell_offer", "args": {"item_id": output["item_id"], "qty": output["quantity"], "price": max(price, 0)}},
    ]
