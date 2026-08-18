"""One-off helper: sign up a new bot account exactly like a human would
from login.html, then print the new player id so you can flag it as a
bot manually in the SQL Editor:

    update player set is_bot = true where id = '<printed id>';

Usage:
    python create_bot.py <username> <email> <password>
"""

import sys

from guild_sdk import SUPABASE_ANON_KEY, SUPABASE_URL
from supabase import create_client


def main() -> None:
    if len(sys.argv) != 4:
        print(__doc__)
        sys.exit(1)

    username, email, password = sys.argv[1:4]
    client = create_client(SUPABASE_URL, SUPABASE_ANON_KEY)
    result = client.auth.sign_up(
        {"email": email, "password": password, "options": {"data": {"username": username}}}
    )
    print(f"created player id: {result.user.id}")
    print(f"now run: update player set is_bot = true where id = '{result.user.id}';")


if __name__ == "__main__":
    main()
