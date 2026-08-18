"""Thin Python wrapper around the game's Supabase project.

Not a new API — every method here mirrors a query or RPC call the
frontend already makes (see public/lib/supabaseClient.js and the page
scripts in public/*.html). A bot authenticates as its own player via
email/password, exactly like a human signing in, so every existing
RLS/ownership check applies unchanged: a bot can only ever act as
itself.
"""

from __future__ import annotations

from dataclasses import dataclass

from supabase import Client, create_client

# Same public anon key + project URL already hardcoded in
# public/lib/supabaseClient.js — not a secret beyond what's already
# shipped to every browser tab.
SUPABASE_URL = "https://dspmysobgqyzkkwdcqit.supabase.co"
SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRzcG15c29iZ3F5emtrd2RjcWl0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODYyMDkyNTYsImV4cCI6MjEwMTc4NTI1Nn0.hR2VxPO54n7Ew1QcX7-IvfRA7bBLVHUiN16CxmgqV34"


@dataclass
class Action:
    """One RPC call a strategy wants executed: rpc_name + its p_-prefixed kwargs."""

    rpc: str
    args: dict


class BotSession:
    def __init__(self, client: Client):
        self.client = client
        self.player_id: str | None = None

    @classmethod
    def login(cls, email: str, password: str, url: str = SUPABASE_URL, anon_key: str = SUPABASE_ANON_KEY) -> "BotSession":
        client = create_client(url, anon_key)
        auth = client.auth.sign_in_with_password({"email": email, "password": password})
        session = cls(client)
        session.player_id = auth.user.id
        return session

    # ------------------------------------------------------------------
    # State getters — plain selects, same shape as the frontend queries.
    # ------------------------------------------------------------------

    def money(self) -> dict:
        row = (
            self.client.table("player")
            .select("money, money_locked")
            .eq("id", self.player_id)
            .single()
            .execute()
        )
        return row.data

    def inventory(self) -> list[dict]:
        rows = (
            self.client.table("player_item")
            .select("item_id, quantity, for_sale_quantity, item(id, name, illustration, is_base, is_tool)")
            .eq("player_id", self.player_id)
            .execute()
        )
        return rows.data or []

    def items(self) -> list[dict]:
        rows = self.client.table("item").select("id, name, illustration, weight, is_base, is_tool").order("name").execute()
        return rows.data or []

    def recipes(self) -> list[dict]:
        rows = self.client.table("recipe").select("id, name").order("name").execute()
        return rows.data or []

    def recipe_items(self, recipe_id: str) -> list[dict]:
        rows = (
            self.client.table("recipe_item")
            .select("quantity, is_output, item(id, name, illustration)")
            .eq("recipe_id", recipe_id)
            .execute()
        )
        return rows.data or []

    def recipe_detail(self, recipe_id: str, name: str | None = None) -> dict:
        """Ingredients needed and what's produced — same tool distinction
        grimoire.html draws: a tool is consumed then returned by the same
        recipe (same item on both sides), so it's neither a real input
        cost nor a real yield."""
        rows = self.recipe_items(recipe_id)
        input_rows = [r for r in rows if not r["is_output"]]
        output_rows = [r for r in rows if r["is_output"]]
        output_ids = {r["item"]["id"] for r in output_rows}
        input_ids = {r["item"]["id"] for r in input_rows}

        def entry(r):
            return {"item_id": r["item"]["id"], "name": r["item"]["name"], "quantity": r["quantity"]}

        return {
            "recipe_id": recipe_id,
            "name": name,
            "inputs": [entry(r) for r in input_rows if r["item"]["id"] not in output_ids],
            "outputs": [entry(r) for r in output_rows if r["item"]["id"] not in input_ids],
            "tools": [entry(r) for r in input_rows if r["item"]["id"] in output_ids],
        }

    def market(self, item_id: str) -> list[dict]:
        rows = (
            self.client.table("offer")
            .select("id, is_sell, price, quantity, created_at")
            .eq("item_id", item_id)
            .order("price")
            .execute()
        )
        return rows.data or []

    def best_offer_summary(self, item_id: str, is_sell: bool) -> dict | None:
        """Best price + total quantity across every offer tied at that
        price — mirrors agora.html's bestOfferSummary()."""
        rows = (
            self.client.table("offer")
            .select("price, quantity")
            .eq("item_id", item_id)
            .eq("is_sell", is_sell)
            .execute()
            .data
            or []
        )
        if not rows:
            return None
        best_price = min(r["price"] for r in rows) if is_sell else max(r["price"] for r in rows)
        total_quantity = sum(r["quantity"] for r in rows if r["price"] == best_price)
        return {"item_id": item_id, "price": best_price, "quantity": total_quantity}

    def sell_tiers(self, item_id: str) -> list[dict]:
        """Every distinct sell price for this item, summed quantity per
        price, sorted ascending (cheapest first) — lets a strategy see
        past just the best price, e.g. to find "the next tier" after
        buying out the cheapest one."""
        rows = (
            self.client.table("offer")
            .select("price, quantity")
            .eq("item_id", item_id)
            .eq("is_sell", True)
            .execute()
            .data
            or []
        )
        totals: dict[int, int] = {}
        for r in rows:
            totals[r["price"]] = totals.get(r["price"], 0) + r["quantity"]
        return [{"item_id": item_id, "price": price, "quantity": qty} for price, qty in sorted(totals.items())]

    def market_summary(self, item_id: str) -> dict:
        """Same {best_sell, best_buy} bundle shown per item card in the
        Agora: best_sell is what you can buy at, best_buy is what you can
        sell into."""
        return {
            "item_id": item_id,
            "best_sell": self.best_offer_summary(item_id, True),
            "best_buy": self.best_offer_summary(item_id, False),
        }

    def own_offers(self) -> list[dict]:
        rows = (
            self.client.table("offer")
            .select("id, is_sell, price, quantity, created_at, item(name, illustration)")
            .eq("player_id", self.player_id)
            .order("created_at", desc=True)
            .execute()
        )
        return rows.data or []

    def fetch_state(self) -> dict:
        """Convenience bundle handed to a strategy's decide()."""
        items = self.items()
        recipes = self.recipes()
        return {
            "money": self.money(),
            "inventory": self.inventory(),
            "items": items,
            # Full ingredients-needed/produced detail per recipe, not just
            # id/name — see recipe_detail().
            "recipes": [self.recipe_detail(r["id"], r["name"]) for r in recipes],
            "own_offers": self.own_offers(),
            # Best buy/sell price + summed volume at that price per item —
            # the same data agora.html shows on each item card.
            "market": {item["id"]: self.market_summary(item["id"]) for item in items},
            # Every distinct sell price tier per item (not just the best),
            # for strategies that need to look past the cheapest offer.
            "sell_tiers": {item["id"]: self.sell_tiers(item["id"]) for item in items},
        }

    # ------------------------------------------------------------------
    # Actions — one per RPC granted to `authenticated`
    # (migrations_clean/02_functions.sql:704-725).
    # ------------------------------------------------------------------

    def craft(self, recipe_id: str, qty: int):
        return self.client.rpc("craft", {"p_recipe_id": recipe_id, "p_qty": qty}).execute()

    def sacrifice(self, item_id: str):
        return self.client.rpc("sacrifice_item", {"p_item_id": item_id}).execute()

    def buy_lootbox(self, qty: int = 1):
        return self.client.rpc("buy_lootbox", {"p_qty": qty}).execute()

    def accept_buy_offer(self, item_id: str, qty: int):
        return self.client.rpc("accept_buy_offer", {"p_item_id": item_id, "p_qty": qty}).execute()

    def accept_sell_offer(self, item_id: str, qty: int):
        return self.client.rpc("accept_sell_offer", {"p_item_id": item_id, "p_qty": qty}).execute()

    def post_buy_offer(self, item_id: str, qty: int, price: int):
        return self.client.rpc("post_buy_offer", {"p_item_id": item_id, "p_qty": qty, "p_price": price}).execute()

    def post_sell_offer(self, item_id: str, qty: int, price: int):
        return self.client.rpc("post_sell_offer", {"p_item_id": item_id, "p_qty": qty, "p_price": price}).execute()

    def cancel_offer(self, offer_id: str):
        return self.client.rpc("cancel_offer", {"p_offer_id": offer_id}).execute()

    def execute(self, action: Action):
        method = getattr(self, action.rpc, None)
        if method is None:
            raise ValueError(f"unknown action: {action.rpc}")
        return method(**action.args)
