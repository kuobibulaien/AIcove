"""Compatibility entry point for the sync-only service."""
from dotenv import load_dotenv

load_dotenv()

from sync_v3.app import app  # noqa: E402

if __name__ == "__main__":
    import os
    import uvicorn

    uvicorn.run(app, host=os.getenv("HOST", "127.0.0.1"),
                port=int(os.getenv("PORT", "8000")))
