"""One pass over every bot in roster.json: log in, decide, act, exit.

No sleeping in-process — this is meant to be woken by an external
schedule (see .github/workflows/bots.yml) and run to completion each
time. Passwords are never stored in roster.json; each entry names an
environment variable to read the password from.
"""

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from guild_sdk import Action, BotSession  # noqa: E402
import strategies  # noqa: E402

ROSTER_PATH = Path(__file__).parent / "roster.json"


def run_bot(entry: dict) -> None:
    name = entry["name"]
    password = os.environ.get(entry["password_env"])
    if not password:
        print(f"[{name}] skipped: {entry['password_env']} is not set")
        return

    session = BotSession.login(entry["email"], password)
    state = session.fetch_state()

    decide = strategies.load(entry["strategy"])
    actions = decide(state) or []

    for action in actions:
        if not isinstance(action, Action):
            action = Action(**action)
        session.execute(action)
        print(f"[{name}] {action.rpc}({action.args})")

    print(f"[{name}] tick complete, {len(actions)} action(s) taken")


def main() -> None:
    roster = json.loads(ROSTER_PATH.read_text())
    for entry in roster:
        try:
            run_bot(entry)
        except Exception as exc:  # one bot's failure shouldn't stop the rest
            print(f"[{entry.get('name', '?')}] error: {exc}")


if __name__ == "__main__":
    main()
