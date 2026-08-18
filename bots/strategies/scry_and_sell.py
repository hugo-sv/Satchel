"""Make a sell offer for the most expensive item it owns (1✦ less than the best offer, never below 11✦, 60✦ if there are no offers) — selling only as much of it as the listing fee can afford if there isn't enough money to list it all — then spend 50% of its remaining cash (rounded down) on scrying."""

MIN_SELL_PRICE = 11
NO_OFFER_FALLBACK_PRICE = 60
LOOTBOX_UNIT_PRICE = 10
SCRY_RATIO_NUM = 50
SCRY_RATIO_DEN = 100


def _value(market: dict, item_id: str) -> int:
    m = market.get(item_id, {})
    if m.get("best_sell"):
        return m["best_sell"]["price"]
    if m.get("best_buy"):
        return m["best_buy"]["price"]
    return 0


def decide(state: dict) -> list:
    inventory = state["inventory"]
    market = state["market"]
    money = state["money"]["money"]

    actions = []
    fee = 0

    owned = [row for row in inventory if row["quantity"] - row["for_sale_quantity"] > 0]
    if owned:
        # An item with no sell offer at all has no market price to
        # compare against, so it's prioritized over ranking it as
        # worthless.
        unpriced = [row for row in owned if not market.get(row["item_id"], {}).get("best_sell")]
        target = unpriced[0] if unpriced else max(owned, key=lambda row: _value(market, row["item_id"]))
        item_id = target["item_id"]
        sell_qty = target["quantity"] - target["for_sale_quantity"]

        # If it already has an open offer for this item, keep that price
        # instead of undercutting — otherwise, when its own offer is the
        # best one, it would shave 1✦ off itself every tick forever.
        own_existing_offer = next(
            (o for o in state["own_offers"] if o["is_sell"] and o["item_id"] == item_id), None
        )
        if own_existing_offer:
            price = own_existing_offer["price"]
        else:
            best_sell = market.get(item_id, {}).get("best_sell")
            price = best_sell["price"] - 1 if best_sell else NO_OFFER_FALLBACK_PRICE
            price = max(price, MIN_SELL_PRICE)

        # If there isn't enough money to cover the listing fee on the
        # whole stack, sell as much of it as the fee allows instead of
        # skipping the sell entirely. fee = ceil(qty*price*5/100) <=
        # money  <=>  qty <= money*20/price (same formula the backend
        # uses to charge the fee).
        max_affordable_qty = (money * 20) // price
        sell_qty = min(sell_qty, max_affordable_qty)

        if sell_qty > 0:
            fee = (sell_qty * price * 5 + 99) // 100
            actions.append({"rpc": "post_sell_offer", "args": {"item_id": item_id, "qty": sell_qty, "price": price}})

    remaining = max(money - fee, 0)
    to_spend = (remaining * SCRY_RATIO_NUM) // SCRY_RATIO_DEN
    qty = to_spend // LOOTBOX_UNIT_PRICE
    if qty > 0:
        actions.append({"rpc": "buy_lootbox", "args": {"qty": qty}})

    return actions
