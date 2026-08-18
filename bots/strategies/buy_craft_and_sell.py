"""Chose a recipe it can buy the ingredients, buy them, craft and sell the output 1✦ less than the best offer. If there are no offers, sells for the total spent + 20✦"""

import random


def decide(state: dict) -> list:
    money = state["money"]["money"]
    market = state["market"]

    eligible = []
    for recipe in state["recipes"]:
        # Tools aren't special-cased — bought fresh like any other
        # ingredient if not affordable, and just as eligible to be the
        # thing sold afterward as a true output.
        needed = recipe["inputs"] + recipe["tools"]
        produced = recipe["outputs"] + recipe["tools"]
        if not produced:
            continue

        total_cost = 0
        buys = []
        affordable = True
        for i in needed:
            offer = market.get(i["item_id"], {}).get("best_sell")
            if not offer or offer["quantity"] < i["quantity"]:
                affordable = False
                break
            total_cost += offer["price"] * i["quantity"]
            buys.append({"rpc": "accept_sell_offer", "args": {"item_id": i["item_id"], "qty": i["quantity"]}})

        if affordable and total_cost <= money:
            eligible.append((recipe, buys, total_cost, produced))

    if not eligible:
        return []

    recipe, buys, total_cost, produced = random.choice(eligible)
    output = produced[0]
    output_offer = market.get(output["item_id"], {}).get("best_sell")
    price = output_offer["price"] - 1 if output_offer else total_cost + 20

    return buys + [
        {"rpc": "craft", "args": {"recipe_id": recipe["recipe_id"], "qty": 1}},
        {"rpc": "post_sell_offer", "args": {"item_id": output["item_id"], "qty": output["quantity"], "price": max(price, 0)}},
    ]
