import hashlib
import os
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path
from unittest.mock import patch

from cryptography.fernet import Fernet
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from auth import create_access_token, decode_token, get_password_hash, router as auth_router
from database import Base, get_db
from models import User
from sync_v3.api import router
from sync_v3.admin import router as admin_router


class SyncHttpTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.env = patch.dict(os.environ, {
            'SYNC_V3_ENCRYPTION_KEY': Fernet.generate_key().decode(),
            'SYNC_V3_BLOB_DIR': str(Path(self.temp.name) / 'blobs'),
        })
        self.env.start()
        self.engine = create_engine('sqlite:///' + str(Path(self.temp.name) / 'db'),
                                    connect_args={'check_same_thread': False})
        Base.metadata.create_all(self.engine)
        sessions = sessionmaker(self.engine, autoflush=False)
        with sessions.begin() as db:
            db.add_all([User(id=i, username=f'user{i}', password_hash='unused', is_admin=i == 2) for i in (1, 2)])
        self.sessions = sessions
        def database():
            with sessions() as db:
                yield db
        app = FastAPI()
        app.include_router(auth_router)
        app.include_router(router)
        app.include_router(admin_router)
        app.dependency_overrides[get_db] = database
        self.client = TestClient(app)
        self.headers = {'Authorization': 'Bearer ' + create_access_token({'sub': '1'})}
        self.other = {'Authorization': 'Bearer ' + create_access_token({'sub': '2'})}
        self.base = '/api/v1/sync/v3'
        self.epoch = self.client.get(self.base + '/status', headers=self.headers).json()['epoch']

    def tearDown(self):
        self.client.close()
        self.engine.dispose()
        self.env.stop()
        self.temp.cleanup()

    def post(self, mutations, **kwargs):
        return self.client.post(self.base + '/push', headers=self.headers, json={
            'epoch': self.epoch, 'device_id': 'phone', 'mutations': mutations, **kwargs})

    def test_two_devices_attachment_raw_message_and_snapshot_roundtrip(self):
        attachment = b'attachment data'
        digest = hashlib.sha256(attachment).hexdigest()
        response = self.client.put(self.base + '/blobs/' + digest, headers=self.headers, content=attachment)
        self.assertEqual(response.status_code, 200, response.text)
        raw = {'content': 'hello', 'raw_payload': '{"role":"assistant","tool_calls":[]}', 'created_at': 100}
        response = self.post([{'op_id': 'create', 'kind': 'messages', 'entity_id': 'm',
                              'base_version': 0, 'payload': raw, 'blob_ids': [digest]}])
        self.assertEqual(response.status_code, 200, response.text)
        pulled = self.client.get(self.base + '/pull', headers=self.headers, params={'epoch': self.epoch}).json()
        self.assertEqual(pulled['changes'][0]['payload'], raw)
        self.assertEqual(self.client.get(self.base + '/blobs/' + digest, headers=self.headers).content, attachment)
        saved = self.client.post(self.base + '/snapshots', headers=self.headers, json={'name': 'test'}).json()
        snapshot = self.client.get(self.base + '/snapshots/' + saved['snapshot_id'], headers=self.headers).json()
        self.assertEqual(snapshot['blob_ids'], [digest])
        notification = self.client.get(self.base + '/wait', headers=self.headers,
                                       params={'epoch': self.epoch, 'after': 0, 'timeout': 0}).json()
        self.assertEqual(notification['cursor'], 1)

    def test_persistent_login_works_without_refresh_and_disabled_account_is_rejected(self):
        with self.sessions.begin() as db:
            db.get(User, 1).password_hash = get_password_hash('fixture-password')
        with patch('auth.PERSISTENT_SESSION_USER_IDS', frozenset({1})):
            response = self.client.post('/api/v1/auth/login', json={
                'username': 'user1', 'password': 'fixture-password'})
            self.assertEqual(response.status_code, 200)
            token = response.json()['access_token']
            self.assertNotIn('exp', decode_token(token))
            headers = {'Authorization': 'Bearer ' + token}
            # A far-future decode does not require a renewal endpoint.
            with patch('jose.jwt.timegm', return_value=4102444800):
                self.assertEqual(self.client.get(self.base + '/status', headers=headers).status_code, 200)
            renewed = self.client.post('/api/v1/auth/refresh', headers=headers)
            self.assertEqual(renewed.status_code, 200)
            self.assertEqual(renewed.json()['access_token'], token)
        with self.sessions.begin() as db:
            db.get(User, 1).is_active = False
        self.assertEqual(self.client.get(self.base + '/status', headers=headers).status_code, 403)
        self.assertEqual(self.client.get('/api/v1/auth/me', headers=headers).status_code, 403)

    def test_refresh_renews_valid_token_and_rejects_expired_or_disabled(self):
        renewed = self.client.post('/api/v1/auth/refresh', headers=self.headers)
        self.assertEqual(renewed.status_code, 200, renewed.text)
        self.assertEqual(renewed.json()['user']['id'], 1)
        token = renewed.json()['access_token']
        self.assertEqual(self.client.get(self.base + '/status',
                                         headers={'Authorization': 'Bearer ' + token}).status_code, 200)
        expired = create_access_token({'sub': '1'}, timedelta(seconds=-1))
        self.assertEqual(self.client.post('/api/v1/auth/refresh',
                                          headers={'Authorization': 'Bearer ' + expired}).status_code, 401)
        self.assertIn(self.client.post('/api/v1/auth/refresh').status_code, (401, 403))
        with self.sessions.begin() as db:
            db.get(User, 1).is_active = False
        self.assertEqual(self.client.post('/api/v1/auth/refresh', headers=self.headers).status_code, 403)

    def test_missing_credentials_and_cross_account_files_and_snapshots(self):
        self.assertIn(self.client.get(self.base + '/status').status_code, (401, 403))
        digest = hashlib.sha256(b'private').hexdigest()
        self.client.put(self.base + '/blobs/' + digest, headers=self.headers, content=b'private')
        self.assertEqual(self.client.get(self.base + '/blobs/' + digest, headers=self.other).status_code, 404)
        saved = self.client.post(self.base + '/snapshots', headers=self.headers, json={'name': 'test'}).json()
        self.assertEqual(self.client.get(self.base + '/snapshots/' + saved['snapshot_id'], headers=self.other).status_code, 404)

    def test_corrupt_upload_not_published(self):
        digest = 'a' * 64
        self.assertEqual(self.client.put(self.base + '/blobs/' + digest, headers=self.headers, content=b'wrong').status_code, 422)
        self.assertEqual(self.client.get(self.base + '/blobs/' + digest, headers=self.headers).status_code, 404)
        self.assertEqual(list((Path(self.temp.name) / 'blobs' / '1').iterdir()), [])

    def test_unknown_contract_is_rejected_without_losing_fields(self):
        response = self.post([{'op_id': 'a', 'kind': 'messages', 'entity_id': 'm',
                              'base_version': 0, 'new_semantics': True}])
        self.assertEqual(response.status_code, 422)
        self.assertEqual(self.post([], protocol_version=4).status_code, 422)
        self.assertEqual(self.client.get(self.base + '/pull', headers=self.headers,
                                         params={'epoch': self.epoch, 'limit': 1000}).status_code, 422)

    def test_provisioned_account_login_token_can_access_sync(self):
        credentials = {'username': 'new-user', 'password': 'local-test-password'}
        with self.sessions.begin() as db:
            db.add(User(username=credentials['username'],
                        password_hash=get_password_hash(credentials['password'])))
        self.assertEqual(self.client.post('/api/v1/auth/register', json=credentials).status_code, 404)
        login = self.client.post('/api/v1/auth/login', json=credentials)
        self.assertEqual(login.status_code, 200, login.text)
        headers = {'Authorization': 'Bearer ' + login.json()['access_token']}
        result = self.client.get(self.base + '/status', headers=headers)
        self.assertEqual(result.status_code, 200, result.text)

    def test_admin_reads_v3_counts_and_disabled_account_tokens_stop_working(self):
        self.post([{'op_id': 'create', 'kind': 'messages', 'entity_id': 'm',
                    'base_version': 0, 'payload': {}}])
        response = self.client.get('/api/v1/admin/users', headers=self.other)
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['users'][0]['sync_counts']['messages'], 1)
        self.assertEqual(self.client.delete('/api/v1/admin/users/1', headers=self.other).status_code, 404)
        response = self.client.put('/api/v1/admin/users/1/active', headers=self.other, json={'is_active': False})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self.client.get(self.base + '/status', headers=self.headers).status_code, 403)
