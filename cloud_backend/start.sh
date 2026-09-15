#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
exec python -m uvicorn sync_v3.app:app --env-file .env --host "${HOST:-127.0.0.1}" --port "${PORT:-8000}"
