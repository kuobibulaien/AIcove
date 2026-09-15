import unittest
from sqlalchemy import select

import test_sync_v3 as fixtures
from sync_v3.contracts import Mutation
from sync_v3.models import Blob, Entity
from sync_v3.service import SyncError


class MediaSyncTest(unittest.TestCase):
    setUp = fixtures.SyncTest.setUp
    tearDown = fixtures.SyncTest.tearDown
    status = fixtures.SyncTest.status
    push = fixtures.SyncTest.push
    pull = fixtures.SyncTest.pull

    def asset(self, original=False, version=0, op='asset'):
        return Mutation(op_id=op, kind='media_assets', entity_id='a' * 64,
            base_version=version,
            payload={'media_version': 1, 'media_id': 'a' * 64,
                'mime_type': 'image/png', 'byte_length': 20,
                'created_at_ms': 1, 'width': 100, 'height': 80,
                'thumbnail_blob': 'b' * 64,
                'original_blob': 'a' * 64 if original else None,
                'locations': [{'device_id': 'phone', 'path': 'generated_images/old.png'}]},
            blob_ids=['b' * 64] + (['a' * 64] if original else []))

    def test_old_original_can_remain_on_phone_while_message_and_thumbnail_sync(self):
        with self.sessions.begin() as db:
            db.add(Blob(user_id=1, digest='b' * 64, size=8))
        self.push([self.asset(), Mutation(op_id='message', kind='messages',
            entity_id='m', base_version=0, media_ids=['a' * 64],
            payload={'raw_payload': '<tts>original text</tts>', 'created_at': 1})])
        docs = self.pull()['changes']
        self.assertIsNone(docs[0]['payload']['original_blob'])
        self.assertEqual(docs[1]['media_ids'], ['a' * 64])
        self.assertEqual(docs[1]['payload']['raw_payload'], '<tts>original text</tts>')
        with self.sessions() as db:
            self.assertIsNone(db.get(Blob, (1, 'a' * 64)))

    def test_deferred_original_still_cannot_pretend_to_be_an_uploaded_blob(self):
        with self.sessions.begin() as db:
            db.add(Blob(user_id=1, digest='b' * 64, size=8))
        with self.assertRaises(SyncError) as result:
            self.push([self.asset(original=True)])
        self.assertEqual(result.exception.code, 'missing_blob')

    def test_media_reference_cannot_cross_account_and_unknown_id_is_rejected(self):
        with self.sessions.begin() as db:
            db.add(Blob(user_id=1, digest='b' * 64, size=8))
        self.push([self.asset()])
        with self.assertRaises(SyncError) as result:
            self.push([Mutation(op_id='cross', kind='messages', entity_id='m',
                base_version=0, media_ids=['a' * 64])], user=2, epoch=self.status(2)['epoch'])
        self.assertEqual(result.exception.code, 'missing_media')

    def test_old_uploaded_original_is_kept_and_delete_retains_media_identity(self):
        with self.sessions.begin() as db:
            db.add_all([Blob(user_id=1, digest='b' * 64, size=8),
                        Blob(user_id=1, digest='a' * 64, size=20)])
        self.push([self.asset(original=True), Mutation(op_id='msg', kind='messages',
            entity_id='m', base_version=0, media_ids=['a' * 64])])
        self.push([Mutation(op_id='delete', kind='messages', entity_id='m',
            base_version=1, action='delete')])
        self.assertEqual(self.pull()['changes'][-1]['media_ids'], ['a' * 64])
        with self.sessions() as db:
            self.assertIsNotNone(db.get(Blob, (1, 'a' * 64)))
            self.assertEqual(len(db.scalars(select(Entity)).all()), 2)

    def test_stale_thumbnail_only_device_cannot_remove_uploaded_original(self):
        with self.sessions.begin() as db:
            db.add_all([Blob(user_id=1, digest='b' * 64, size=8),
                        Blob(user_id=1, digest='a' * 64, size=20)])
        self.push([self.asset(original=True)])
        stale = self.asset(op='stale')
        stale.payload['locations'] = [{'device_id': 'desktop', 'path': '/pictures/original.png'}]
        result = self.push([stale])['results'][0]
        self.assertEqual(result['status'], 'applied')
        self.assertEqual(result['document']['payload']['original_blob'], 'a' * 64)
        self.assertEqual(len(result['document']['payload']['locations']), 2)
        self.assertIn('a' * 64, result['document']['blob_ids'])

    def test_stable_media_identity_can_differ_from_original_file_digest(self):
        with self.sessions.begin() as db:
            db.add_all([Blob(user_id=1, digest='b' * 64, size=8),
                        Blob(user_id=1, digest='c' * 64, size=20)])
        metadata = self.asset().payload
        metadata.update(original_sha256='c' * 64, original_blob='c' * 64)
        result = self.push([Mutation(op_id='logical-id', kind='media_assets', entity_id='a' * 64,
            base_version=0, payload=metadata, blob_ids=['b' * 64, 'c' * 64])])
        self.assertEqual(result['results'][0]['document']['entity_id'], 'a' * 64)

    def test_original_usage_and_latest_chat_reference_are_additive(self):
        with self.sessions.begin() as db:
            db.add(Blob(user_id=1, digest='b' * 64, size=8))
        first = self.asset()
        first.payload.update(original_required=True, last_chat_at_ms=100)
        self.push([first])
        stale = self.asset(op='older-chat')
        stale.payload.update(original_required=False, last_chat_at_ms=2)
        payload = self.push([stale])['results'][0]['document']['payload']
        self.assertTrue(payload['original_required'])
        self.assertEqual(payload['last_chat_at_ms'],100)

    def test_old_client_cannot_replace_a_complete_message_snapshot(self):
        self.push([Mutation(op_id='snapshot',kind='messages',entity_id='m',base_version=0,
            payload={'message_snapshot_version':1,'row':{'id':'m'},'message_blocks':[],'message_projection_mappings':[]})])
        with self.assertRaises(SyncError) as caught:
            self.push([Mutation(op_id='legacy',kind='messages',entity_id='m',base_version=1,payload={'row':{'id':'m'}})])
        self.assertEqual(caught.exception.code,'client_upgrade_required')


if __name__ == '__main__':
    unittest.main()
