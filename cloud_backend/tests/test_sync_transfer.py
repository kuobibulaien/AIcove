import gzip
import hashlib
import io
import json
import unittest
import zipfile

from fastapi.testclient import TestClient
from starlette.middleware.gzip import GZipMiddleware
from sync_v3.limits import RequestLimits
import test_sync_v3_http as http_fixture


class SyncTransferTest(unittest.TestCase):
    def setUp(self):
        http_fixture.SyncHttpTest.setUp(self)
        app = self.client.app
        self.client.close()
        self.client = TestClient(GZipMiddleware(RequestLimits(app), minimum_size=1024))

    tearDown = http_fixture.SyncHttpTest.tearDown

    def archive(self, values):
        result = io.BytesIO()
        with zipfile.ZipFile(result, 'w', zipfile.ZIP_STORED) as output:
            for name, value in values:
                output.writestr(name, value)
        return result.getvalue()

    def test_compressed_json_preserves_raw_content_and_responses(self):
        raw = 'complete raw text ' * 20000
        body = json.dumps({'epoch': self.epoch, 'device_id': 'phone', 'mutations': [
            {'op_id': 'gzip', 'kind': 'messages', 'entity_id': 'm', 'base_version': 0,
             'payload': {'content': raw}}]}).encode()
        compressed = gzip.compress(body)
        self.assertLess(len(compressed), len(body) / 10)
        response = self.client.post(self.base + '/push', content=compressed,
            headers={**self.headers, 'Content-Type': 'application/json', 'Content-Encoding': 'gzip'})
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(response.json()['results'][0]['document']['payload']['content'], raw)
        self.assertEqual(response.headers['content-encoding'], 'gzip')

    def test_compression_limit_applies_after_decompression(self):
        headers = {**self.headers, 'Content-Type': 'application/json', 'Content-Encoding': 'gzip'}
        response = self.client.post(self.base + '/push', content=gzip.compress(b'x' * (17 * 1024 * 1024)), headers=headers)
        self.assertEqual(response.status_code, 413)
        self.assertEqual(self.client.post(self.base + '/push', content=b'broken', headers=headers).status_code, 400)

    def test_batch_upload_is_verified_idempotent_and_account_scoped(self):
        values = [(hashlib.sha256(data).hexdigest(), data) for data in (b'thumbnail-one', b'thumbnail-two', b'voice')]
        body = self.archive(values)
        for _ in range(2):
            response = self.client.put(self.base + '/blobs/batch', content=body, headers=self.headers)
            self.assertEqual(response.status_code, 200, response.text)
            self.assertEqual({item['digest'] for item in response.json()['blobs']}, {name for name, _ in values})
        for name, data in values:
            self.assertEqual(self.client.get(self.base + '/blobs/' + name, headers=self.headers).content, data)
            self.assertEqual(self.client.get(self.base + '/blobs/' + name, headers=self.other).status_code, 404)

    def test_bad_batch_never_publishes_partial_files(self):
        valid = hashlib.sha256(b'valid').hexdigest()
        for invalid in ['a' * 64, '../escape']:
            response = self.client.put(self.base + '/blobs/batch', content=self.archive([(valid, b'valid'), (invalid, b'wrong')]), headers=self.headers)
            self.assertEqual(response.status_code, 422, response.text)
            self.assertEqual(self.client.get(self.base + '/blobs/' + valid, headers=self.headers).status_code, 404)

    def test_batch_count_and_expanded_size_are_bounded(self):
        values = [(hashlib.sha256(str(i).encode()).hexdigest(), str(i).encode()) for i in range(65)]
        self.assertEqual(self.client.put(self.base + '/blobs/batch', content=self.archive(values), headers=self.headers).status_code, 413)
        data = b'z' * (17 * 1024 * 1024)
        result = io.BytesIO()
        with zipfile.ZipFile(result, 'w', zipfile.ZIP_DEFLATED) as out:
            out.writestr(hashlib.sha256(data).hexdigest(), data)
        self.assertEqual(self.client.put(self.base + '/blobs/batch', content=result.getvalue(), headers=self.headers).status_code, 413)
