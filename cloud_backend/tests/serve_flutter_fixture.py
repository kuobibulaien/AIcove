"""Disposable loopback server for the real Flutter-to-Python sync contract test."""
import os
import socket
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from cryptography.fernet import Fernet

temporary = tempfile.TemporaryDirectory(prefix='aicove-flutter-sync-')
os.environ.update({
    'DATABASE_URL': 'sqlite:///' + str(Path(temporary.name) / 'sync.db'),
    'SYNC_V3_BLOB_DIR': str(Path(temporary.name) / 'blobs'),
    'SYNC_V3_ENCRYPTION_KEY': Fernet.generate_key().decode(),
    'SECRET_KEY': 'disposable-loopback-integration-test-secret',
})

from database import init_db, SessionLocal
from auth import get_password_hash
from models import User
from sync_v3.app import app
from sync_v3.account_limits import LoginLimits
import uvicorn

# This loopback fixture runs several independent two-device cases per minute.
# Production login limits are exercised separately, and remain unchanged.
for middleware in app.user_middleware:
    if middleware.cls is LoginLimits:
        middleware.kwargs['attempts'] = 100

init_db()
with SessionLocal.begin() as db:
    for number in range(1, 33):
        db.add(User(id=number, username=f'fixture{number}', unique_id=f'test-{number}',
                    password_hash=get_password_hash('integration-test-password')))
listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(128)
print(f'READY {listener.getsockname()[1]}', flush=True)
try:
    uvicorn.run(app, fd=listener.fileno(), log_level='error', access_log=False)
finally:
    listener.close()
    temporary.cleanup()
