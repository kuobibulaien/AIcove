"""Load the local server environment before initializing database/auth modules."""
from dotenv import load_dotenv

load_dotenv('.env', override=False)

from .maintenance import main  # noqa: E402

main()
