"""Schema metadata and edit clocks must not create durable false conflicts."""
import unittest
from unittest.mock import patch

import test_sync_v3 as fixtures
from sync_v3.contracts import Mutation
from sync_v3.models import Entity, ReadEntry
from sync_v3.service import SyncEngine
from sync_v3.setting_merge import content


class EquivalentConflictTest(unittest.TestCase):
    setUp = fixtures.SyncTest.setUp
    tearDown = fixtures.SyncTest.tearDown
    status = fixtures.SyncTest.status
    push = fixtures.SyncTest.push
    put = fixtures.SyncTest.put
    pull = fixtures.SyncTest.pull
    setting = fixtures.SyncTest.setting

    def seed_conflict(self, incoming, current_payload=None, deleted=False,
                      blob_ids=None, media_ids=None, missing=False):
        """Write the legacy shape directly, without invoking new self-healing."""
        with self.sessions() as db:
            engine = SyncEngine(db, 1, self.vault)
            account = engine._account(lock=True)
            current = None if missing else engine._write(
                account, incoming.kind, incoming.entity_id,
                current_payload if current_payload is not None else incoming.payload,
                blob_ids or [], deleted, media_ids or [])
            conflict = engine._write(account, '_conflicts', incoming.op_id, {
                'device_id': 'legacy', 'incoming': incoming.model_dump(),
                'current': current, 'created_at': 1,
            }, sorted(set(incoming.blob_ids) | set(blob_ids or [])),
                media_ids=sorted(set(incoming.media_ids) | set(media_ids or [])))
            db.commit()
            return conflict['seq']

    def document(self, kind, entity_id):
        with self.sessions() as db:
            return SyncEngine(db, 1, self.vault)._decode(db.get(Entity, (1, kind, entity_id)))

    def test_content_ignores_only_top_level_metadata(self):
        payload = {'client_schema': 19, 'setting_times_version': 1, 'setting_times': {},
                   'row': {'client_schema': 'business', 'setting_times': 'nested'}}
        self.assertEqual(content(payload), {'row': payload['row']})

    def test_schema_only_stale_upload_is_equivalent(self):
        self.push([self.put(client_schema=18, text='same')])
        result = self.push([self.put(op='schema-copy', client_schema=19, text='same')])['results'][0]
        self.assertEqual(result['status'], 'applied')
        self.assertEqual(result['document']['version'], 1)

    def test_setting_merge_preserves_max_schema_and_nested_business_keys(self):
        for old_schema, new_schema in ((18, 19), (19, 18)):
            with self.subTest(old_schema=old_schema):
                entity_id = str(old_schema)
                def mutation(op, version, schema, value, at):
                    return Mutation(op_id=op + entity_id, kind='settings', entity_id=entity_id,
                        base_version=version, payload={'client_schema': schema,
                            'storage': 'preference', 'key': 'nested-test',
                            'json_value': {'client_schema': value, 'kept': {'setting_times': 42}},
                            'setting_times_version': 1,
                            'setting_times': {'client_schema': {'at_ms': at, 'device_id': 'phone'}}})
                self.push([mutation('base', 0, old_schema, 'old', 1)])
                result = self.push([mutation('merge', 0, new_schema, 'new', 2)])['results'][0]
                self.assertEqual(result['status'], 'merged')
                payload = result['document']['payload']
                self.assertEqual(payload['client_schema'], 19)
                self.assertEqual(payload['json_value'], {
                    'client_schema': 'new', 'kept': {'setting_times': 42}})

    def test_each_read_boundary_heals_history_and_commits_indexed_tombstone(self):
        for method in ('status', 'pull', 'read_page', 'conflicts'):
            with self.subTest(method=method):
                incoming = self.put(id=method, op=method, client_schema=18, text='same')
                before = self.seed_conflict(incoming, {'client_schema': 19, 'text': 'same'})
                with self.sessions() as db:
                    engine = SyncEngine(db, 1, self.vault)
                    if method in ('status', 'conflicts'):
                        result = getattr(engine, method)()
                    else:
                        result = getattr(engine, method)(self.epoch, after=before)
                    if method == 'status':
                        self.assertEqual(result['cursor'], before + 1)
                    elif method == 'conflicts':
                        self.assertEqual(result, [])
                    else:
                        docs = result['changes' if method == 'pull' else 'documents']
                        self.assertEqual(len(docs), 1)
                        self.assertTrue(docs[0]['deleted'])
                        self.assertEqual(result['through'], before + 1)
                tombstone = self.document('_conflicts', method)
                self.assertTrue(tombstone['deleted'])
                self.assertEqual(tombstone['version'], 2)
                with self.sessions() as db:
                    self.assertTrue(db.get(ReadEntry, (1, before + 1)).hidden)
                self.assertEqual(self.status()['cursor'], before + 1)
                self.assertEqual(self.document('_conflicts', method)['version'], 2)

    def test_real_conflicts_reference_differences_missing_and_delete_mismatch_survive(self):
        cases = [
            ('body', self.put(op='body', text='incoming'), {'text': 'current'}),
            ('nested', self.put(op='nested', row={'client_schema': 18}), {'row': {'client_schema': 19}}),
            ('blobs', self.put(op='blobs', text='same').model_copy(update={'blob_ids': ['a' * 64]}), {'text': 'same'}),
            ('media', self.put(op='media', text='same').model_copy(update={'media_ids': ['b' * 64]}), {'text': 'same'}),
            ('deleted', self.put(op='deleted', text='same'), {'text': 'same'}),
            ('missing', self.put(op='missing', text='same'), {'text': 'same'}),
        ]
        for name, incoming, payload in cases:
            incoming = incoming.model_copy(update={'entity_id': name})
            self.seed_conflict(incoming, payload, deleted=name == 'deleted', missing=name == 'missing')
        with self.sessions() as db:
            conflicts = SyncEngine(db, 1, self.vault).conflicts()
        self.assertEqual({c['conflict_id'] for c in conflicts}, {c[0] for c in cases})

    def test_delete_equivalence_retires_only_when_current_is_deleted(self):
        incoming = Mutation(op_id='delete-conflict', kind='messages', entity_id='m',
                            base_version=0, action='delete')
        self.seed_conflict(incoming, {'text': 'retained'}, deleted=True, blob_ids=['a' * 64])
        self.status()
        self.assertTrue(self.document('_conflicts', incoming.op_id)['deleted'])
        live_delete = incoming.model_copy(update={'op_id': 'live-delete', 'entity_id': 'live'})
        self.seed_conflict(live_delete, {'text': 'live'})
        self.status()
        self.assertFalse(self.document('_conflicts', live_delete.op_id)['deleted'])

    def test_clocks_do_not_authorize_retiring_different_content(self):
        for same in (True, False):
            name = str(same)
            incoming = self.setting(name, 0, {'voice_file': 'incoming'}, {
                'voice_file': {'at_ms': 100, 'device_id': 'old'}}).model_copy(
                    update={'entity_id': name})
            payload = {**incoming.payload, 'client_schema': 19,
                'row': {**incoming.payload['row'], 'voice_file': 'incoming' if same else 'different'},
                'setting_times': {'voice_file': {'at_ms': 999, 'device_id': 'new'}}}
            self.seed_conflict(incoming, payload)
        self.status()
        self.assertTrue(self.document('_conflicts', 'True')['deleted'])
        self.assertFalse(self.document('_conflicts', 'False')['deleted'])

    def test_fixed_read_watermark_keeps_history_until_next_delta(self):
        for method in ('pull', 'read_page'):
            with self.subTest(method=method):
                incoming = self.put(id=method, op=method, text='same')
                before = self.seed_conflict(incoming)
                with self.sessions() as db:
                    result = getattr(SyncEngine(db, 1, self.vault), method)(
                        self.epoch, after=before, through=before)
                self.assertEqual(result['through'], before)
                self.assertEqual(result['changes' if method == 'pull' else 'documents'], [])
                self.assertTrue(self.document('_conflicts', method)['deleted'])
                self.assertTrue(self.pull(before)['changes'][0]['deleted'])

    def test_successful_mutation_retires_conflict_in_same_transaction(self):
        for branch in ('applied', 'equivalent', 'merged'):
            with self.subTest(branch=branch):
                incoming = self.setting(branch, 0, {'voice_file': 'new'}, {})
                incoming = incoming.model_copy(update={'entity_id': branch})
                before = self.seed_conflict(incoming, {**incoming.payload,
                    'row': {**incoming.payload['row'], 'voice_file': 'old' if branch != 'equivalent' else 'new'}})
                payload = dict(incoming.payload)
                if branch == 'merged':
                    payload['setting_times'] = {'voice_file': {'at_ms': 10, 'device_id': 'phone'}}
                mutation = incoming.model_copy(update={'op_id': 'success-' + branch,
                    'base_version': 1 if branch == 'applied' else 0, 'payload': payload})
                result = self.push([mutation])
                self.assertNotEqual(result['results'][0]['status'], 'conflict')
                self.assertTrue(self.document('_conflicts', branch)['deleted'])
                self.assertEqual(result['cursor'], before + (1 if branch == 'equivalent' else 2))

    def test_failed_mutation_rolls_back_business_write_and_conflict_retirement(self):
        incoming = self.put(op='pending', text='new')
        before = self.seed_conflict(incoming, {'text': 'old'})
        with patch.object(SyncEngine, '_save_receipt', side_effect=RuntimeError('receipt failed')):
            with self.assertRaisesRegex(RuntimeError, 'receipt failed'):
                self.push([self.put(version=1, op='change', text='new')])
        self.assertEqual(self.document('messages', 'm')['payload'], {'text': 'old'})
        self.assertFalse(self.document('_conflicts', 'pending')['deleted'])
        self.assertEqual(self.status()['cursor'], before)


if __name__ == '__main__':
    unittest.main()
