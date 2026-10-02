#!/usr/bin/env bash
# Starts only the disposable loopback fixture; never uses a deployed backend.
set -euo pipefail

: "${AICOVE_SYNC_TEST_BACKEND:?Set AICOVE_SYNC_TEST_BACKEND to the local cloud_backend checkout}"
: "${AICOVE_SYNC_TEST_PYTHON:?Set AICOVE_SYNC_TEST_PYTHON to its prepared Python executable}"
if [[ ! -f "$AICOVE_SYNC_TEST_BACKEND/tests/serve_flutter_fixture.py" ]]; then
  printf 'Local cloud fixture not found in AICOVE_SYNC_TEST_BACKEND\n' >&2
  exit 2
fi
if [[ ! -x "$AICOVE_SYNC_TEST_PYTHON" ]]; then
  printf 'AICOVE_SYNC_TEST_PYTHON is not executable\n' >&2
  exit 2
fi
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec tool/flutterw test --no-pub test/features/sync/cloud_sync_contract_test.dart "$@"
