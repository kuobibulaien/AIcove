"""Recent-first reads preserve a fixed snapshot and omit superseded rows."""
import unittest
import test_sync_v3 as fixtures


class ReadTest(unittest.TestCase):
    setUp = fixtures.SyncTest.setUp
    tearDown = fixtures.SyncTest.tearDown
    status = fixtures.SyncTest.status
    push = fixtures.SyncTest.push
    put = fixtures.SyncTest.put
    def snapshot(self, name, at, **extra):
        return self.put(name, op=name, row={
            'id': name, 'conversation_id': 'c', 'created_at': at,
            'deleted_at': None, 'content': name,
        }, message_snapshot_version=1, message_blocks=[],
            message_projection_mappings=[], **extra)

    def read(self, **kwargs):
        from sync_v3.service import SyncEngine
        with self.sessions() as db:
            return SyncEngine(db, 1, self.vault).read_page(self.epoch, **kwargs)

    def test_recent_head_excludes_old_history_and_obsolete_children(self):
        from sync_v3.contracts import Mutation
        self.push([Mutation(op_id='child', kind='message_blocks', entity_id='b', base_version=0,
                            payload={'row': {'id': 'b', 'message_id': 'm0'}})])
        self.push([self.snapshot(f'm{i}', 1000+i) for i in range(80)])
        head = self.read(stage='head')
        self.assertEqual(len(head['documents']), 50)
        self.assertEqual({d['entity_id'] for d in head['documents']},
                         {f'm{i}' for i in range(30, 80)})
        history = self.read(stage='history', through=head['through'])
        self.assertEqual(len(history['documents']), 30)
        self.assertTrue(all(d['kind'] == 'messages' for d in history['documents']))

    def test_head_resume_does_not_move_when_a_new_message_arrives(self):
        self.push([self.snapshot(f'm{i}', 1000+i) for i in range(60)])
        first = self.read(stage='head', limit=12)
        self.push([self.snapshot('new', 9999)])
        ids = {d['entity_id'] for d in first['documents']}
        page = first
        while page['has_more']:
            page = self.read(stage='head', after=page['next_cursor'],
                             through=first['through'], limit=12)
            ids.update(d['entity_id'] for d in page['documents'])
        self.assertEqual(ids, {f'm{i}' for i in range(10, 60)})
        delta = self.read(stage='delta', after=first['through'])
        self.assertEqual([d['entity_id'] for d in delta['documents']], ['new'])

    def test_delta_coalesces_revisions_without_losing_latest_delete(self):
        from sync_v3.contracts import Mutation
        self.push([self.snapshot('m', 1)])
        before = self.status()['cursor']
        self.push([self.put('m', version=1, op='edit', row={'content': 'changed'},
                            message_snapshot_version=1)])
        self.push([Mutation(op_id='del', kind='messages', entity_id='m',
                            base_version=2, action='delete')])
        docs = self.read(stage='delta', after=before)['documents']
        self.assertEqual(len(docs), 1)
        self.assertEqual(docs[0]['version'], 3)
        self.assertTrue(docs[0]['deleted'])

    def test_recent_classification_uses_history_timestamp_not_upload_order(self):
        self.push([self.snapshot(f'new{i}', 1000+i) for i in range(50)])
        self.push([self.snapshot('imported-old', 1)])
        self.assertNotIn('imported-old', {d['entity_id'] for d in self.read(stage='head')['documents']})

    def test_additive_index_backfill_is_complete_and_idempotent(self):
        from sqlalchemy import delete, select, func
        from sync_v3.models import ReadEntry
        from sync_v3.reads import backfill_read_index
        self.push([self.snapshot(f'm{i}', i) for i in range(80)])
        with self.sessions() as db:
            db.execute(delete(ReadEntry)); db.commit()
            backfill_read_index(db, self.vault)
            backfill_read_index(db, self.vault)
            self.assertEqual(db.scalar(select(func.count()).select_from(ReadEntry)),80)
        self.assertEqual(len(self.read(stage='head')['documents']),50)

    def test_read_does_not_include_another_accounts_same_ids(self):
        self.push([self.snapshot('m', 1)])
        epoch=self.status(2)['epoch']
        self.push([self.put('m',op='m',secret='other account')],user=2,epoch=epoch)
        self.assertEqual(self.read(stage='head')['documents'][0]['payload']['row']['content'],'m')

    def test_missing_blob_inventory_is_account_scoped(self):
        from sync_v3.models import Blob
        from sync_v3.service import SyncEngine
        with self.sessions.begin() as db:
            db.add(Blob(user_id=1,digest='a'*64,size=10))
            db.add(Blob(user_id=2,digest='b'*64,size=10))
        with self.sessions() as db:
            self.assertEqual(SyncEngine(db,1,self.vault).missing_blobs(['a'*64,'b'*64,'c'*64]),
                             {'missing':['b'*64,'c'*64]})

    def test_dependencies_use_the_same_watermark(self):
        from sync_v3.contracts import Mutation
        self.push([Mutation(op_id='c1',kind='conversations',entity_id='c',base_version=0,
                            payload={'row':{'id':'c','title':'before'}})])
        self.push([self.snapshot('m',1)])
        boundary=self.status()['cursor']
        self.push([Mutation(op_id='c2',kind='conversations',entity_id='c',base_version=1,
                            payload={'row':{'id':'c','title':'after'}})])
        page=self.read(stage='delta',after=1,through=boundary)
        self.assertEqual(page['documents'][0]['entity_id'],'m')
        self.assertEqual(page['dependencies'][0]['payload']['row']['title'],'before')

    def test_legacy_child_includes_parent_and_conversation(self):
        from sync_v3.contracts import Mutation
        self.push([Mutation(op_id='c1',kind='conversations',entity_id='c',base_version=0,
                            payload={'row':{'id':'c'}})])
        self.push([self.put('m',op='m',row={'id':'m','conversation_id':'c'})])
        before=self.status()['cursor']
        self.push([Mutation(op_id='b',kind='message_blocks',entity_id='b',base_version=0,
                            payload={'row':{'id':'b','message_id':'m'}})])
        page=self.read(stage='delta',after=before)
        self.assertEqual({d['kind'] for d in page['dependencies']},{'messages','conversations'})
