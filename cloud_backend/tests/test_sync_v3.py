"""Behavioral regressions with independent devices and isolated account stores."""
import concurrent.futures
import tempfile
import unittest
from pathlib import Path

from cryptography.fernet import Fernet
from sqlalchemy import create_engine, select
from sqlalchemy.orm import sessionmaker

from database import Base
from models import User
from sync_v3.contracts import Mutation, Push
from sync_v3.crypto import Vault
from sync_v3.models import Entity, Change, Receipt
from sync_v3.service import SyncEngine, SyncError


class SyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.engine = create_engine('sqlite:///' + str(Path(self.tmp.name) / 'test.db'))
        Base.metadata.create_all(self.engine)
        self.sessions = sessionmaker(self.engine, autoflush=False)
        self.vault = Vault(Fernet.generate_key())
        with self.sessions.begin() as db:
            db.add_all([User(id=i, username=str(i), password_hash='test') for i in (1, 2)])
        self.epoch = self.status()['epoch']

    def tearDown(self):
        self.engine.dispose()
        self.tmp.cleanup()

    def status(self, user=1):
        with self.sessions() as db:
            return SyncEngine(db, user, self.vault).status()

    def push(self, mutations, user=1, device='phone', epoch=None):
        with self.sessions() as db:
            return SyncEngine(db, user, self.vault).push(Push(
                epoch=epoch or self.epoch, device_id=device, mutations=mutations))

    def put(self, id='m', version=0, op='op', **payload):
        return Mutation(op_id=op, kind='messages', entity_id=id,
                        base_version=version, payload=payload)

    def pull(self, cursor=0, limit=100, through=None):
        with self.sessions() as db:
            return SyncEngine(db, 1, self.vault).pull(self.epoch, cursor, limit, through)

    def test_same_timestamp_pagination_and_original_history_time(self):
        self.push([self.put(str(i), op=str(i), created_at=123, raw_payload='original') for i in range(100)])
        self.push([self.put('100', op='100', created_at=123)])
        first = self.pull(limit=50)
        second = self.pull(first['next_cursor'], 50, first['through'])
        third = self.pull(second['next_cursor'], 50, first['through'])
        docs = first['changes'] + second['changes'] + third['changes']
        self.assertEqual(len({d['entity_id'] for d in docs}), 101)
        self.assertTrue(all(d['payload']['created_at'] == 123 for d in docs))
        self.assertFalse(third['has_more'])

    def test_edit_delete_restore_propagate_after_first_pull(self):
        self.push([self.put(text='first')])
        cursor = self.pull()['next_cursor']
        self.push([self.put(version=1, op='edit', text='edited')])
        self.push([Mutation(op_id='delete', kind='messages', entity_id='m', base_version=2, action='delete')])
        self.push([self.put(version=3, op='restore', text='restored')])
        changes = self.pull(cursor)['changes']
        self.assertEqual([d['version'] for d in changes], [2, 3, 4])
        self.assertTrue(changes[1]['deleted'])
        self.assertEqual(changes[2]['payload']['text'], 'restored')

    def test_retry_is_exact_and_changed_operation_id_is_rejected(self):
        mutation = self.put(text='one')
        first = self.push([mutation])['results']
        self.assertEqual(self.push([mutation])['results'], first)
        self.assertEqual(self.status()['cursor'], 1)
        with self.assertRaises(SyncError):
            self.push([self.put(text='different')])

    def test_two_offline_edits_preserve_conflicting_payload(self):
        self.push([self.put(text='base')])
        self.push([self.put(version=1, op='phone', text='phone')])
        result = self.push([self.put(version=1, op='mac', text='mac')], device='mac')['results'][0]
        self.assertEqual(result['status'], 'conflict')
        self.assertEqual(result['current']['payload']['text'], 'phone')
        with self.sessions() as db:
            conflicts = SyncEngine(db, 1, self.vault).conflicts()
        self.assertEqual(conflicts[0]['incoming']['payload']['text'], 'mac')

    def test_malformed_batch_rolls_back_preceding_writes(self):
        with self.assertRaises(SyncError):
            self.push([self.put(), self.put(id='missing', op='bad', version=8)])
        self.assertEqual(self.pull()['changes'], [])
        with self.sessions() as db:
            self.assertEqual(len(db.scalars(select(Receipt)).all()), 0)

    def test_missing_attachment_rejects_whole_batch(self):
        mutation = self.put().model_copy(update={'blob_ids': ['a' * 64]})
        with self.assertRaises(SyncError):
            self.push([mutation])
        self.assertEqual(self.status()['cursor'], 0)

    def test_user_isolation_even_with_same_entity_and_operation_ids(self):
        self.push([self.put(text='private')])
        second_epoch = self.status(2)['epoch']
        self.push([self.put(text='other')], user=2, epoch=second_epoch)
        self.assertEqual(self.pull()['changes'][0]['payload']['text'], 'private')

    def test_snapshot_is_fixed_while_new_changes_arrive_and_restore_is_ordered(self):
        self.push([self.put(text='saved')])
        with self.sessions() as db:
            snapshot = SyncEngine(db, 1, self.vault).create_snapshot('checkpoint')
        self.push([self.put(version=1, op='edit', text='later'), self.put('new', op='new')])
        with self.sessions() as db:
            svc = SyncEngine(db, 1, self.vault)
            saved = svc.snapshot(snapshot['snapshot_id'])
            self.assertEqual(saved['entities'][0]['payload']['text'], 'saved')
            from sync_v3.contracts import Restore
            request = Restore(op_id='restore', device_id='mac', epoch=self.epoch, expected_cursor=3)
            result = svc.restore(snapshot['snapshot_id'], request)
            self.assertEqual(result, svc.restore(snapshot['snapshot_id'], request))
        docs = self.pull(3)['changes']
        self.assertEqual(len(docs), 2)
        self.assertEqual(next(d for d in docs if d['entity_id'] == 'm')['payload']['text'], 'saved')
        self.assertTrue(next(d for d in docs if d['entity_id'] == 'new')['deleted'])

    def test_concurrent_writers_never_publish_sequence_before_commit(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda i: self.push([self.put(str(i), op=str(i))]), range(20)))
        self.assertEqual([d['seq'] for d in self.pull()['changes']], list(range(1, 21)))

    def test_epoch_and_future_cursor_rejected(self):
        with self.assertRaises(SyncError):
            self.push([self.put()], epoch='old-server')
        with self.assertRaises(SyncError):
            self.pull(1)

    def test_payload_and_conflicts_are_encrypted_at_rest(self):
        self.push([self.put(text='private-value')])
        with self.sessions() as db:
            entity = db.scalars(select(Entity)).one()
            change = db.scalars(select(Change)).one()
            self.assertNotIn('private-value', entity.document)
            self.assertNotIn('private-value', change.document)

    def test_bootstrap_watermark_survives_changes_between_pages(self):
        self.push([self.put('a', op='a', text='old'), self.put('b', op='b')])
        with self.sessions() as db:
            first = SyncEngine(db, 1, self.vault).bootstrap(self.epoch, limit=1)
        self.push([self.put('b', version=1, op='edit', text='new'), self.put('c', op='c')])
        with self.sessions() as db:
            second = SyncEngine(db, 1, self.vault).bootstrap(
                self.epoch, first['next_cursor'], 1, first['through'])
        self.assertEqual(second['entities'][0]['version'], 1)
        self.assertEqual(second['next_cursor'], 2)
        self.assertFalse(second['has_more'])
        self.assertEqual(len(self.pull(2)['changes']), 2)

    def test_conflict_resolution_requires_current_preview_and_preserves_delete_payload(self):
        from sync_v3.contracts import Restore
        self.push([self.put(text='base')])
        self.push([self.put(version=1, op='edit', text='keep')])
        result = self.push([Mutation(op_id='delete', kind='messages', entity_id='m',
                                     base_version=1, action='delete')])['results'][0]
        with self.sessions() as db:
            service = SyncEngine(db, 1, self.vault)
            with self.assertRaises(SyncError):
                service.resolve(result['conflict_id'], Restore(op_id='resolve', device_id='mac',
                                epoch=self.epoch, expected_cursor=2), True)
            resolved = service.resolve(result['conflict_id'], Restore(op_id='resolve', device_id='mac',
                                       epoch=self.epoch, expected_cursor=3), True)
            self.assertEqual(resolved['status'], 'resolved')
            self.assertEqual(service.conflicts(), [])
        deleted = next(d for d in self.pull(3)['changes'] if d['kind'] == 'messages')
        self.assertEqual(deleted['payload']['text'], 'keep')
        self.assertTrue(deleted['deleted'])

    def test_portable_backup_into_empty_account_preserves_raw_files_and_tombstones(self):
        import asyncio
        from sync_v3.blobs import BlobStore
        from sync_v3.maintenance import export_snapshot, import_archive
        import hashlib
        content = b'media-bytes'
        digest = hashlib.sha256(content).hexdigest()
        blobs = BlobStore(Path(self.tmp.name) / 'files')
        async def chunks():
            yield content
        with self.sessions() as db:
            asyncio.run(blobs.upload(SyncEngine(db, 1, self.vault), digest, chunks()))
        mutation = self.put(raw_payload={'role': 'assistant', 'tool_calls': []}).model_copy(update={'blob_ids': [digest]})
        self.push([mutation])
        self.push([Mutation(op_id='delete', kind='messages', entity_id='m', base_version=1, action='delete')])
        path = Path(self.tmp.name) / 'portable.aicove-cloud'
        with self.sessions() as db:
            service = SyncEngine(db, 1, self.vault)
            snapshot = service.create_snapshot('portable')
            export_snapshot(service, snapshot['snapshot_id'], path, blobs)
            with self.assertRaises(FileExistsError):
                export_snapshot(service, snapshot['snapshot_id'], path, blobs)
        with self.sessions() as db:
            service = SyncEngine(db, 2, self.vault)
            result = import_archive(service, path, blobs)
            self.assertEqual(result['entities'], 1)
            self.assertNotEqual(result['epoch'], self.epoch)
            document = service.pull(result['epoch'])['changes'][0]
            self.assertTrue(document['deleted'])
            self.assertEqual(document['payload']['raw_payload'], {'role': 'assistant', 'tool_calls': []})
            self.assertEqual(blobs.download(service, digest).read_bytes(), content)
            with self.assertRaises(SyncError):
                import_archive(service, path, blobs)

    def test_conflict_snapshot_retains_both_versions_attachments(self):
        from sync_v3.models import Blob
        old, incoming = 'a' * 64, 'b' * 64
        with self.sessions.begin() as db:
            db.add_all([Blob(user_id=1, digest=d, size=1) for d in (old, incoming)])
        self.push([self.put().model_copy(update={'blob_ids': [old]})])
        self.push([self.put(op='conflict').model_copy(update={'blob_ids': [incoming]})])
        self.push([self.put(version=1, op='replace', text='without attachment')])
        with self.sessions() as db:
            service = SyncEngine(db, 1, self.vault)
            saved = service.create_snapshot('both versions')
            self.assertEqual(service.snapshot(saved['snapshot_id'])['blob_ids'], [old, incoming])

    def test_wrong_key_is_detected_even_before_first_user_document(self):
        from sync_v3.initialization import validate_installation
        from cryptography.fernet import InvalidToken
        with self.sessions() as db:
            validate_installation(db, self.vault)
            validate_installation(db, self.vault)
            with self.assertRaises(InvalidToken):
                validate_installation(db, Vault(Fernet.generate_key()))

    def test_paged_snapshot_restore_and_archive_cover_more_than_one_page(self):
        from sync_v3.contracts import Restore
        from sync_v3.blobs import BlobStore
        from sync_v3.maintenance import export_snapshot, import_archive
        self.push([self.put(str(i), op=str(i), text='saved') for i in range(100)])
        self.push([self.put(str(i), op=str(i), text='saved') for i in range(100, 200)])
        self.push([self.put(str(i), op=str(i), text='saved') for i in range(200, 205)])
        with self.sessions() as db:
            service = SyncEngine(db, 1, self.vault)
            saved = service.create_snapshot('paged')
        self.push([self.put('0', op='edit', version=1, text='changed'), self.put('later', op='later')])
        with self.sessions() as db:
            service = SyncEngine(db, 1, self.vault)
            pages = list(service.snapshot_pages(saved['snapshot_id']))
            self.assertEqual([len(p['entities']) for p in pages], [100, 100, 5])
            self.assertEqual(pages[0]['entities'][0]['payload']['text'], 'saved')
            service.restore(saved['snapshot_id'], Restore(op_id='restore', device_id='mac',
                            epoch=self.epoch, expected_cursor=207))
            self.assertEqual(service.status()['cursor'], 413)
            export_snapshot(service, saved['snapshot_id'], Path(self.tmp.name) / 'paged', BlobStore(self.tmp.name))
        with self.sessions() as db:
            service = SyncEngine(db, 2, self.vault)
            result = import_archive(service, Path(self.tmp.name) / 'paged', BlobStore(self.tmp.name))
            self.assertEqual(result['entities'], 205)
