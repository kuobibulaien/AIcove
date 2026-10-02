# Test fixture boundaries

`transport_preset_fixture.dart` contains an independently authored minimal
transport preset. Ordinary tests need no archived third-party preset files.
For private compatibility checks, set `AICOVE_KEMINI_FIXTURE` to the absolute
path of a local original JSON export. An explicit invalid path fails clearly;
it never silently falls back to the synthetic fixture. Do not commit originals.

The cloud contract test starts `cloud_backend/tests/serve_flutter_fixture.py`
with a temporary database, disposable accounts and a loopback HTTP port.
Run it from the Flutter package with:

```sh
AICOVE_SYNC_TEST_BACKEND=/path/to/aicove/cloud_backend \
AICOVE_SYNC_TEST_PYTHON=/path/to/prepared/venv/bin/python \
bash tool/test_cloud_contract.sh --reporter json
```

The Python environment must already contain the backend dependencies. The
entry point does not install dependencies or contact a production service.
To include this contract test in a full `tool/flutterw test` run, provide the
same two environment variables. Missing prerequisites remain a clear error,
and teardown is safe if the server could not start.
