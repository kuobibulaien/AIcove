"""Run the production ASGI entry point against a fresh on-disk database."""
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import httpx
from cryptography.fernet import Fernet


class ProductionProcessTest(unittest.TestCase):
    def test_cli_generates_private_config_and_creates_account_without_printing_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, PYTHONPATH=str(Path.cwd()))
            for key in ('DATABASE_URL', 'SECRET_KEY', 'SYNC_V3_ENCRYPTION_KEY', 'SYNC_V3_BLOB_DIR'):
                environment.pop(key, None)
            command = [sys.executable, '-m', 'sync_v3']
            initialized = subprocess.run(command + ['init-config'], cwd=directory, env=environment,
                                         check=True, capture_output=True, text=True)
            config = Path(directory) / '.env'
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            contents = config.read_text()
            self.assertNotIn('SECRET_KEY=', initialized.stdout)
            again = subprocess.run(command + ['init-config'], cwd=directory, env=environment, capture_output=True)
            self.assertNotEqual(again.returncode, 0)
            self.assertEqual(config.read_text(), contents)
            created = subprocess.run(command + ['create-user', '--username', 'cli-user', '--admin'],
                                     cwd=directory, env=environment, input='fixture-password\nfixture-password\n',
                                     capture_output=True, text=True)
            self.assertEqual(created.returncode, 0, created.stderr)
            self.assertIn('Created user', created.stdout)

    def test_read_snapshot_does_not_block_sync_commit(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ,
                DATABASE_URL='sqlite:///' + str(Path(directory) / 'db'),
                SYNC_V3_ENCRYPTION_KEY=Fernet.generate_key().decode())
            script = """import sqlite3
from database import init_db, SessionLocal
from models import User
from sync_v3.service import SyncEngine
from sync_v3.crypto import Vault
from sync_v3.contracts import Push
init_db()
with SessionLocal.begin() as db:
    db.add(User(id=1,username='reader-writer-fixture',password_hash='unused'))
with SessionLocal() as db:
    sync=SyncEngine(db,1,Vault())
    epoch=sync.status()['epoch']
    reader=sqlite3.connect(db.bind.url.database)
    try:
        reader.execute('BEGIN')
        assert reader.execute('SELECT cursor FROM sync3_accounts WHERE user_id=1').fetchone()[0]==0
        db.connection().exec_driver_sql('PRAGMA busy_timeout=100')
        result=sync.push(Push(epoch=epoch,device_id='fixture',mutations=[dict(op_id='write',kind='messages',entity_id='m',base_version=0,payload={'text':'fixture'})]))
        assert result['cursor']==1
        assert reader.execute('SELECT cursor FROM sync3_accounts WHERE user_id=1').fetchone()[0]==0
        reader.rollback()
        assert reader.execute('SELECT cursor FROM sync3_accounts WHERE user_id=1').fetchone()[0]==1
    finally:
        reader.close()
"""
            result = subprocess.run([sys.executable, '-c', script], env=environment,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_login_sync_restart_and_public_route_boundary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = dict(os.environ,
                DATABASE_URL='sqlite:///' + str(root / 'db'),
                SYNC_V3_BLOB_DIR=str(root / 'blobs'),
                SYNC_V3_ENCRYPTION_KEY=Fernet.generate_key().decode(),
                SECRET_KEY='test-only-signing-key-' + 'x' * 40,
                ALLOWED_ORIGINS='')
            seed = '''from database import init_db, SessionLocal
from models import User
from auth import get_password_hash
init_db()
with SessionLocal.begin() as db:
    db.add(User(username='tester', password_hash=get_password_hash('test-password')))
'''
            subprocess.run([sys.executable, '-c', seed], env=environment, check=True, capture_output=True)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            url = f'http://127.0.0.1:{port}'
            def start():
                log = (root / 'server.log').open('ab')
                process = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'sync_v3.app:app',
                    '--host', '127.0.0.1', '--port', str(port), '--no-access-log'],
                    env=environment, stdout=log, stderr=log)
                log.close()
                try:
                    for _ in range(100):
                        if process.poll() is not None:
                            self.fail((root / 'server.log').read_text())
                        try:
                            if httpx.get(url + '/health', trust_env=False, timeout=0.5).status_code == 200:
                                return process
                        except httpx.TransportError:
                            pass
                        time.sleep(0.1)
                    self.fail('Production entry point did not become ready')
                except BaseException:
                    process.terminate()
                    process.wait(timeout=10)
                    raise
            process = start()
            try:
                with httpx.Client(base_url=url, trust_env=False) as client:
                    login = client.post('/api/v1/auth/login', json={'username': 'tester', 'password': 'test-password'})
                    self.assertEqual(login.status_code, 200, login.text)
                    headers = {'Authorization': 'Bearer ' + login.json()['access_token']}
                    base = '/api/v1/sync/v3'
                    state = client.get(base + '/status', headers=headers).json()
                    payload = {'epoch': state['epoch'], 'device_id': 'phone', 'mutations': [{
                        'op_id': 'm', 'kind': 'messages', 'entity_id': 'm', 'base_version': 0,
                        'payload': {'raw_payload': {'role': 'user', 'content': 'fixture'}}}]}
                    response = client.post(base + '/push', headers=headers, json=payload)
                    self.assertEqual(response.status_code, 200, response.text)
                    for route in ('/api/v1/sync/v2/pull', '/api/v1/auth/register',
                                  '/api/v1/auth/bootstrap-admin', '/api/v1/agent-context-admin/document'):
                        self.assertEqual(client.get(route, headers=headers).status_code, 404)
                    self.assertEqual(client.get('/api/v1/admin/users', headers=headers).status_code, 403)
                    self.assertEqual(client.post(base + '/push', headers=headers,
                                                content=b'x' * (16 * 1024 * 1024 + 1)).status_code, 413)
                process.terminate()
                process.wait(timeout=10)
                process = start()
                with httpx.Client(base_url=url, trust_env=False) as client:
                    restarted = client.get(base + '/status', headers=headers).json()
                    self.assertEqual(restarted['epoch'], state['epoch'])
                    self.assertEqual(restarted['cursor'], 1)
                    page = client.get(base + '/pull', headers=headers, params={'epoch': state['epoch']}).json()
                    self.assertEqual(page['changes'][0]['payload']['raw_payload']['content'], 'fixture')
                    retried = client.post(base + '/push', headers=headers, json=payload).json()
                    self.assertEqual(retried['cursor'], 1)
                check_owner = '''from database import SessionLocal
from models import User
from sqlalchemy.exc import IntegrityError
with SessionLocal() as db:
    db.delete(db.query(User).filter(User.username == 'tester').one())
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
    else:
        raise AssertionError('Account with sync records was physically deleted')
'''
                checked = subprocess.run([sys.executable, '-c', check_owner], env=environment, capture_output=True, text=True)
                self.assertEqual(checked.returncode, 0, checked.stderr)
            finally:
                process.terminate()
                process.wait(timeout=10)
