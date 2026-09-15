import unittest

from auth import get_password_hash, verify_password
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient


class AccountSecurityTest(unittest.TestCase):
    def test_explicit_short_password_provisioning_keeps_default_policy(self):
        with self.assertRaises(HTTPException):
            get_password_hash('839274')
        hashed = get_password_hash('839274', minimum_bytes=6)
        self.assertTrue(verify_password('839274', hashed))
        self.assertFalse(verify_password('839275', hashed))
        with self.assertRaises(HTTPException):
            get_password_hash('12345', minimum_bytes=6)

    def test_login_limit_ignores_spoofed_forwarding_headers_and_expires(self):
        from sync_v3.account_limits import LoginLimits
        now = [0.0]
        app = FastAPI()
        app.add_middleware(LoginLimits, attempts=3, window=60,
                           clock=lambda: now[0])

        @app.post('/api/v1/auth/login')
        def login():
            return {'ok': True}

        client = TestClient(app)
        for i in range(3):
            self.assertEqual(client.post('/api/v1/auth/login',
                headers={'X-Forwarded-For': f'192.0.2.{i}'}).status_code, 200)
        result = client.post('/api/v1/auth/login')
        self.assertEqual(result.status_code, 429)
        self.assertEqual(result.headers['retry-after'], '60')
        now[0] = 61
        self.assertEqual(client.post('/api/v1/auth/login').status_code, 200)

    def test_limit_does_not_apply_to_regular_authenticated_requests(self):
        from sync_v3.account_limits import LoginLimits
        app = FastAPI()
        app.add_middleware(LoginLimits, attempts=1)

        @app.get('/api/v1/auth/me')
        def me():
            return {'id': 1}

        client = TestClient(app)
        for _ in range(4):
            self.assertEqual(client.get('/api/v1/auth/me').status_code, 200)


if __name__ == '__main__':
    unittest.main()
