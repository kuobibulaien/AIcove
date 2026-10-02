"""Retiring legacy services must preserve sync accounts and stored data."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class CloudRetirementTest(unittest.TestCase):
    def test_compatibility_entrypoint_exposes_only_sync_and_account_routes(self):
        from main import app
        from sync_v3.app import app as sync_app

        self.assertIs(app, sync_app)
        paths = {route.path for route in app.routes}
        self.assertIn('/api/v1/auth/login', paths)
        self.assertIn('/api/v1/sync/v3/push', paths)
        for path in paths:
            self.assertTrue(path in {'/health', '/docs', '/docs/oauth2-redirect',
                                    '/openapi.json', '/redoc', '/api/v1/auth/login', '/api/v1/auth/refresh',
                                    '/api/v1/auth/me', '/api/v1/admin/users',
                                    '/api/v1/admin/users/{user_id}/active'}
                            or path.startswith('/api/v1/sync/v3/'), path)

    def test_existing_accounts_and_legacy_tables_survive_initialization(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ,
                PYTHONPATH=str(Path(__file__).resolve().parents[1]),
                DATABASE_URL='sqlite:///' + str(Path(directory) / 'db'))
            script = '''
from database import engine, init_db, SessionLocal, Base
from models import User
from auth import get_password_hash, verify_password
with engine.begin() as connection:
    connection.exec_driver_sql("""CREATE TABLE users (
        id INTEGER PRIMARY KEY, username VARCHAR(100) UNIQUE NOT NULL,
        email VARCHAR(200), password_hash VARCHAR(255) NOT NULL,
        user_level INTEGER, unique_id VARCHAR(50), expires_at DATETIME,
        is_admin BOOLEAN, is_active BOOLEAN, created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )""")
    connection.exec_driver_sql("INSERT INTO users (id,username,password_hash,user_level,unique_id,is_admin,is_active) VALUES (7,'existing',?,4,'same-id',0,1)", (get_password_hash('fixture-password'),))
    connection.exec_driver_sql('CREATE TABLE old_data (payload TEXT)')
    connection.exec_driver_sql("INSERT INTO old_data VALUES ('keep-me')")
init_db()
with SessionLocal() as db:
    user = db.get(User, 7)
    assert user.unique_id == 'same-id'
    assert verify_password('fixture-password', user.password_hash)
    assert 'user_level' not in user.to_dict() and 'expires_at' not in user.to_dict()
    db.add(User(username='new-account', password_hash=get_password_hash('other-password')))
    db.commit()
with engine.connect() as connection:
    assert connection.exec_driver_sql('SELECT user_level FROM users WHERE id=7').scalar() == 4
    assert connection.exec_driver_sql('SELECT payload FROM old_data').scalar() == 'keep-me'
assert all(name == 'users' or name.startswith('sync3_') for name in Base.metadata.tables)
'''
            result = subprocess.run([sys.executable, '-c', script], cwd=directory,
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
