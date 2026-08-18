"""Strategy contract.

A strategy is a module exposing a single function:

    def decide(state: dict) -> list[Action]

`state` is whatever BotSession.fetch_state() returns (money, inventory,
items, recipes, own_offers). `Action` is guild_sdk.Action(rpc, args) —
`rpc` matches a BotSession method name (e.g. "craft", "sacrifice",
"post_sell_offer"), `args` are that method's kwargs.

run_bots.py looks up a bot's strategy module by name (the "strategy"
field in roster.json) and calls its decide() once per tick. Write your
own strategy module here and point a roster entry at it — the runner,
SDK, and hosting don't need to change.
"""

from importlib import import_module


def load(name: str):
    module = import_module(f"strategies.{name}")
    if not hasattr(module, "decide"):
        raise ValueError(f"strategy '{name}' has no decide() function")
    return module.decide
