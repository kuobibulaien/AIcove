"""Transactional sync engine. No transport or platform paths in this layer."""
import hashlib
import time
import uuid

from sqlalchemy import select, update, func
from sqlalchemy.exc import IntegrityError

from .contracts import KINDS, Mutation, Push, Restore, canonical
from .models import Account, Blob, Change, Entity, Receipt, Snapshot, ReadEntry
from .reads import index_document, read_page
from .setting_merge import merge_settings, content, media_references, explicit_setting_edit, SETTING_KINDS
from .general_settings import project_payload, public_document


class SyncError(Exception):
    def __init__(self, code, message, status=409):
        self.code, self.message, self.status = code, message, status
        super().__init__(message)


class SyncEngine:
    def __init__(self, db, user_id, vault):
        self.db, self.user, self.vault = db, int(user_id), vault

    def _account(self, lock=False):
        account = self.db.get(Account, self.user)
        if account is None:
            try:
                with self.db.begin_nested():
                    self.db.add(Account(user_id=self.user, epoch=str(uuid.uuid4()), cursor=0))
                    self.db.flush()
            except IntegrityError:
                pass  # Another connection initialized the same account.
        if lock:
            # A write lock works in SQLite and PostgreSQL. Sequence allocation is
            # serialized with the actual commit, not an independent sequence.
            self.db.execute(update(Account).where(Account.user_id == self.user)
                            .values(cursor=Account.cursor))
        return self.db.get(Account, self.user, populate_existing=True)

    def status(self):
        account = self._account()
        result = {'protocol_version': 3, 'payload_version': 1,
                  'epoch': account.epoch, 'cursor': account.cursor,
                  'kinds': sorted(KINDS), 'max_batch': 100,
                  'media_version': 1, 'recent_original_days': 30,
                  'json_gzip': True, 'blob_batch_version': 1,
                  'message_snapshot_version': 1, 'media_usage_version': 1,
                  'indexed_read_version': 1, 'blob_probe_version': 1}
        result['setting_times_version'] = 1
        self.db.commit()
        return result

    def _check_epoch(self, account, epoch):
        if account.epoch != epoch:
            raise SyncError('epoch_mismatch', '服务器数据代次已变化，请重新绑定并完整同步')

    def _decode(self, entity):
        return public_document(self.vault.open(entity.document)) if entity else None

    def _write(self, account, kind, entity_id, payload, blob_ids, deleted=False, media_ids=None):
        entity = self.db.get(Entity, (self.user, kind, entity_id))
        version = (entity.version if entity else 0) + 1
        account.cursor += 1
        document = {'seq': account.cursor, 'kind': kind, 'entity_id': entity_id,
                    'version': version, 'payload_version': 1, 'deleted': deleted,
                    'payload': payload, 'blob_ids': blob_ids, 'media_ids': media_ids or []}
        encrypted = self.vault.seal(document)
        if entity:
            entity.version, entity.document = version, encrypted
            entity.deleted = deleted
        else:
            self.db.add(Entity(user_id=self.user, kind=kind, entity_id=entity_id,
                               version=version, deleted=deleted, document=encrypted))
        self.db.add(Change(user_id=self.user, seq=account.cursor, kind=kind,
                           entity_id=entity_id, document=encrypted))
        self.db.add(ReadEntry(**index_document(self.user, document)))
        self.db.flush()
        return document

    def _receipt(self, op_id, request):
        fingerprint = hashlib.sha256(canonical(request).encode()).hexdigest()
        receipt = self.db.get(Receipt, (self.user, op_id))
        if receipt and receipt.request_hash != fingerprint:
            raise SyncError('op_id_reused', '同一操作编号不能用于不同内容')
        result = self.vault.open(receipt.result) if receipt else None
        if result is not None:
            for key in ('document', 'current'):
                if key in result:
                    result[key] = public_document(result[key])
        return fingerprint, result

    def _save_receipt(self, op_id, fingerprint, result):
        self.db.add(Receipt(user_id=self.user, op_id=op_id, request_hash=fingerprint,
                            result=self.vault.seal(result)))
        self.db.flush()

    def _mutate(self, account, device, mutation):
        request = {'device_id': device, **mutation.model_dump()}
        fingerprint, previous = self._receipt(mutation.op_id, request)
        if previous is not None:
            return previous
        # Fingerprint the original immutable request above, then enforce the
        # current scope on values we publish. Retried legacy requests stay safe.
        mutation = mutation.model_copy(update={'payload': project_payload(mutation.kind, mutation.payload)})
        if mutation.kind == 'settings' and mutation.payload.get('key') == 'aicove.ui_models.v1':
            mutation = mutation.model_copy(update={'media_ids': sorted(
                set(mutation.media_ids) & media_references(mutation.payload))})
        entity = self.db.get(Entity, (self.user, mutation.kind, mutation.entity_id))
        current = self._decode(entity)
        version = entity.version if entity else 0
        merged = None
        if (mutation.kind == 'messages' and mutation.action == 'put' and current
                and current['payload'].get('message_snapshot_version') == 1
                and mutation.payload.get('message_snapshot_version') != 1):
            raise SyncError('client_upgrade_required', '请更新客户端后同步完整消息快照')
        child_owner = {'message_blocks':'message_id','message_projection_mappings':'raw_message_id'}.get(mutation.kind)
        if child_owner:
            payload = current['payload'] if mutation.action == 'delete' and current else mutation.payload
            owner = payload.get('row',{}).get(child_owner)
            parent = self.db.get(Entity,(self.user,'messages',owner)) if owner else None
            if parent and self._decode(parent)['payload'].get('message_snapshot_version') == 1:
                raise SyncError('client_upgrade_required', '请随完整消息快照同步显示结构')
        if mutation.base_version > version:
            raise SyncError('future_version', '本地版本高于云端版本，请检查服务器恢复状态')
        for digest in mutation.blob_ids:
            if self.db.get(Blob, (self.user, digest)) is None:
                raise SyncError('missing_blob', '请先完成附件上传')
        for media_id in mutation.media_ids:
            media = self.db.get(Entity, (self.user, 'media_assets', media_id))
            if media is None or media.deleted:
                raise SyncError('missing_media', '请先同步图片或附件的身份信息')
        if mutation.action == 'put' and current:
            merged = merge_settings(mutation.kind, current, mutation.payload,
                                    mutation.blob_ids, mutation.media_ids)
        if mutation.kind == 'media_assets' and mutation.action == 'put' and current and not current['deleted']:
            # Media identity is immutable; availability is additive across devices.
            # An old thumbnail-only client must never remove an uploaded original.
            previous = current['payload']
            payload = dict(mutation.payload)
            for field in ('original_sha256', 'original_blob'):
                if previous.get(field) and payload.get(field) and previous[field] != payload[field]:
                    raise SyncError('media_identity_changed', '同一附件身份不能指向不同原图')
                payload[field] = previous.get(field) or payload.get(field)
            payload['thumbnail_blob'] = previous.get('thumbnail_blob') or payload.get('thumbnail_blob')
            payload['original_required'] = previous.get('original_required', False) or payload.get('original_required', False)
            payload['last_chat_at_ms'] = max(previous.get('last_chat_at_ms', previous.get('created_at_ms', 0)),
                                             payload.get('last_chat_at_ms', payload.get('created_at_ms', 0)))
            locations = {(item['device_id'], item['path']) for item in
                         previous.get('locations', []) + payload.get('locations', [])}
            payload['locations'] = [{'device_id': device, 'path': path} for device, path in sorted(locations)]
            if len(payload['locations']) > 100:
                raise SyncError('media_locations_full', '附件保存位置超过支持数量')
            blobs = sorted({value for value in (payload.get('thumbnail_blob'), payload.get('original_blob')) if value})
            if canonical(payload) == canonical(previous):
                document = current
            else:
                document = self._write(account, mutation.kind, mutation.entity_id, payload, blobs)
            result = {'op_id': mutation.op_id, 'status': 'applied', 'document': document}
        elif (mutation.action == 'put' and current and not current['deleted']
              and canonical(content(mutation.payload) if mutation.kind in SETTING_KINDS else mutation.payload)
                  == canonical(content(current['payload']) if mutation.kind in SETTING_KINDS else current['payload'])
              and set(mutation.blob_ids) == set(current['blob_ids'])
              and set(mutation.media_ids) == set(current.get('media_ids', []))
              and not (mutation.kind in SETTING_KINDS
                       and mutation.payload.get('setting_times') != current['payload'].get('setting_times')
                       and any(stamp['at_ms'] > 0 for stamp in mutation.payload.get('setting_times', {}).values()))):
            # A second device can publish the same content from an older
            # baseline. A receipt is durable; a new revision is unnecessary.
            result = {'op_id': mutation.op_id, 'status': 'applied', 'document': current}
        elif merged is not None:
            payload, references = merged
            document = current if (canonical(payload) == canonical(current['payload'])
                                   and set(references) == set(current.get('media_ids', []))) else self._write(
                account, mutation.kind, mutation.entity_id, payload, mutation.blob_ids, media_ids=references)
            result = {'op_id': mutation.op_id, 'status': 'merged', 'document': document}
        elif (version != mutation.base_version or
              (mutation.action == 'put' and mutation.kind in SETTING_KINDS and current
               and current['payload'].get('setting_times_version') == 1
               and mutation.payload.get('setting_times_version') != 1)):
            # Keep the original ID and its references stable. Conflicts are
            # separate durable records, never silently duplicated chat rows.
            conflict_id = str(uuid.uuid4())
            self._write(account, '_conflicts', conflict_id, {
                'device_id': device, 'incoming': mutation.model_dump(),
                'current': current, 'created_at': int(time.time() * 1000),
            }, sorted(set(mutation.blob_ids) | set(current['blob_ids'])),
                media_ids=sorted(set(mutation.media_ids) | set(current.get('media_ids', []))))
            result = {'op_id': mutation.op_id, 'status': 'conflict',
                      'conflict_id': conflict_id, 'current': current}
        else:
            # Tombstones retain the last payload for explicit restore and backup.
            deleting = mutation.action == 'delete'
            payload = current['payload'] if deleting and current else mutation.payload
            blobs = current['blob_ids'] if deleting and current else mutation.blob_ids
            media_ids = current.get('media_ids', []) if deleting and current else mutation.media_ids
            document = self._write(account, mutation.kind, mutation.entity_id, payload, blobs, deleting, media_ids)
            result = {'op_id': mutation.op_id, 'status': 'applied', 'document': document}
        self._save_receipt(mutation.op_id, fingerprint, result)
        return result

    def push(self, request: Push):
        try:
            account = self._account(lock=True)
            self._check_epoch(account, request.epoch)
            results = [self._mutate(account, request.device_id, m) for m in request.mutations]
            response = {'results': results, 'cursor': account.cursor, 'epoch': account.epoch}
            self.db.commit()  # No successful response is observable before this.
            return response
        except Exception:
            self.db.rollback()
            raise

    def pull(self, epoch, after=0, limit=100, through=None):
        account = self._account()
        self._check_epoch(account, epoch)
        if not 1 <= limit <= 100 or after < 0:
            raise SyncError('invalid_page', '无效的分页参数', 422)
        boundary = account.cursor if through is None else through
        if not after <= boundary <= account.cursor:
            raise SyncError('invalid_cursor', '无效的同步进度')
        query = select(Change).where(
            Change.user_id == self.user, Change.seq > after, Change.seq <= boundary
        ).order_by(Change.seq).limit(limit + 1)
        return {'epoch': account.epoch, **self._page(query, boundary, limit, 'changes')}

    def read_page(self, epoch, after=0, limit=512, through=None, stage='delta'):
        account = self._account()
        self._check_epoch(account, epoch)
        boundary = account.cursor if through is None else through
        if (not 0 <= after <= boundary <= account.cursor or not 1 <= limit <= 512
                or stage not in ('head', 'history', 'delta')):
            raise SyncError('invalid_page', '无效的同步分页')
        return read_page(self, boundary, after, stage, limit)

    def missing_blobs(self, digests):
        present = set(self.db.scalars(select(Blob.digest).where(
            Blob.user_id == self.user, Blob.digest.in_(digests))))
        return {'missing': [digest for digest in digests if digest not in present]}

    def _page(self, query, boundary, limit, key):
        docs, size, more = [], 0, False
        rows = self.db.scalars(query).yield_per(1)
        try:
            for row in rows:
                document = public_document(self.vault.open(row.document))
                document_size = len(canonical(document).encode())
                if docs and (len(docs) >= limit or size + document_size > 8 * 1024 * 1024):
                    more = True
                    break
                docs.append(document)
                size += document_size
        finally:
            rows.close()
        return {key: docs, 'through': boundary,
                'next_cursor': docs[-1]['seq'] if more else boundary, 'has_more': more}

    def bootstrap(self, epoch, after=0, limit=100, through=None):
        """Latest version of every entity at a fixed watermark, paged by seq."""
        account = self._account()
        self._check_epoch(account, epoch)
        boundary = account.cursor if through is None else through
        if not 0 <= after <= boundary <= account.cursor or not 1 <= limit <= 100:
            raise SyncError('invalid_cursor', '无效的同步进度')
        return {'epoch': account.epoch, **self._state_page(boundary, after, limit)}

    def _state_page(self, boundary, after, limit):
        latest = select(func.max(Change.seq)).where(
            Change.user_id == self.user, Change.seq <= boundary
        ).group_by(Change.kind, Change.entity_id)
        query = select(Change).where(
            Change.user_id == self.user, Change.seq.in_(latest), Change.seq > after
        ).order_by(Change.seq).limit(limit + 1)
        return self._page(query, boundary, limit, 'entities')

    def conflicts(self):
        rows = self.db.scalars(select(Entity).where(
            Entity.user_id == self.user, Entity.kind == '_conflicts')).all()
        return [dict(d['payload'], conflict_id=d['entity_id'], latest=self._decode(self.db.get(Entity,
                    (self.user, d['payload']['incoming']['kind'], d['payload']['incoming']['entity_id']))))
                for r in rows if not (d := self._decode(r))['deleted']]

    def resolve(self, conflict_id, request: Restore, use_incoming: bool):
        try:
            account = self._account(lock=True)
            self._check_epoch(account, request.epoch)
            fingerprint, previous = self._receipt(request.op_id, {
                **request.model_dump(), 'conflict_id': conflict_id, 'use_incoming': use_incoming})
            if previous is not None:
                self.db.rollback()
                return previous
            if account.cursor != request.expected_cursor:
                raise SyncError('changed_since_preview', '云端已有新变化，请刷新后再处理冲突')
            conflict = self._decode(self.db.get(Entity, (self.user, '_conflicts', conflict_id)))
            if conflict is None or conflict['deleted']:
                raise SyncError('missing_conflict', '冲突不存在或已处理', 404)
            incoming = Mutation(**conflict['payload']['incoming'])
            current = self._decode(self.db.get(Entity, (self.user, incoming.kind, incoming.entity_id)))
            if use_incoming:
                payload, blobs = incoming.payload, incoming.blob_ids
                if incoming.action == 'delete':
                    current = self._decode(self.db.get(Entity, (self.user, incoming.kind, incoming.entity_id)))
                    payload, blobs = current['payload'], current['blob_ids']
                if incoming.action != 'delete':
                    payload = explicit_setting_edit(incoming.kind, payload, current['payload'],
                                                    request.device_id, int(time.time() * 1000))
                self._write(account, incoming.kind, incoming.entity_id, payload,
                            blobs, incoming.action == 'delete',
                            current.get('media_ids', []) if incoming.action == 'delete' else incoming.media_ids)
            else:
                current = self._decode(self.db.get(Entity, (self.user, incoming.kind, incoming.entity_id)))
                payload = current['payload'] if current['deleted'] else explicit_setting_edit(
                    incoming.kind, current['payload'], current['payload'], request.device_id, int(time.time() * 1000))
                self._write(account, incoming.kind, incoming.entity_id, payload,
                            current['blob_ids'], current['deleted'], current.get('media_ids', []))
            self._write(account, '_conflicts', conflict_id, conflict['payload'], conflict['blob_ids'], True, conflict.get('media_ids', []))
            result = {'status': 'resolved', 'cursor': account.cursor}
            self._save_receipt(request.op_id, fingerprint, result)
            self.db.commit()
            return result
        except Exception:
            self.db.rollback()
            raise

    def create_snapshot(self, name):
        try:
            account = self._account(lock=True)
            manifest = {'protocol_version': 3, 'epoch': account.epoch,
                        'cursor': account.cursor}
            snapshot = Snapshot(user_id=self.user, snapshot_id=str(uuid.uuid4()), name=name,
                                cursor=account.cursor, created_at=int(time.time() * 1000),
                                manifest=self.vault.seal(manifest))
            self.db.add(snapshot)
            result = self._snapshot_info(snapshot)
            self.db.commit()
            return result
        except Exception:
            self.db.rollback()
            raise

    @staticmethod
    def _snapshot_info(snapshot):
        return {k: getattr(snapshot, k) for k in ('snapshot_id', 'name', 'cursor', 'created_at')}

    def snapshots(self):
        return [self._snapshot_info(s) for s in self.db.scalars(select(Snapshot).where(
            Snapshot.user_id == self.user).order_by(Snapshot.created_at.desc()))]

    def snapshot(self, snapshot_id, after=0, limit=100):
        snapshot = self.db.get(Snapshot, (self.user, snapshot_id))
        if not snapshot:
            raise SyncError('missing_snapshot', '备份不存在', 404)
        manifest = self.vault.open(snapshot.manifest)
        if not 0 <= after <= snapshot.cursor or not 1 <= limit <= 100:
            raise SyncError('invalid_cursor', '无效的备份分页参数')
        page = self._state_page(snapshot.cursor, after, limit)
        return {**manifest, **page,
                'blob_ids': sorted({b for d in page['entities'] for b in d['blob_ids']})}

    def snapshot_pages(self, snapshot_id):
        after = 0
        while True:
            page = self.snapshot(snapshot_id, after)
            yield page
            if not page['has_more']:
                return
            after = page['next_cursor']

    def restore(self, snapshot_id, request: Restore):
        try:
            account = self._account(lock=True)
            self._check_epoch(account, request.epoch)
            fingerprint, previous = self._receipt(request.op_id, {
                'snapshot_id': snapshot_id, **request.model_dump()})
            if previous is not None:
                self.db.rollback()
                return previous
            if request.expected_cursor != account.cursor:
                raise SyncError('changed_since_preview', '备份预览后云端已有变化，请刷新后重试')
            saved = set()
            for page in self.snapshot_pages(snapshot_id):
                for document in page['entities']:
                    key = (document['kind'], document['entity_id'])
                    saved.add(key)
                    current = self._decode(self.db.get(Entity, (self.user, *key)))
                    payload = document['payload'] if document['deleted'] else explicit_setting_edit(
                        document['kind'], document['payload'], current['payload'] if current else None,
                        request.device_id, int(time.time() * 1000))
                    self._write(account, *key, payload, document['blob_ids'], document['deleted'], document.get('media_ids', []))
            current = self.db.execute(select(Entity.kind, Entity.entity_id).where(Entity.user_id == self.user)).all()
            for key in current:
                if key in saved:
                    continue
                old = self._decode(self.db.get(Entity, (self.user, *key)))
                if not old['deleted']:
                    self._write(account, *key, old['payload'], old['blob_ids'], True, old.get('media_ids', []))
            result = {'status': 'restored', 'cursor': account.cursor}
            self._save_receipt(request.op_id, fingerprint, result)
            self.db.commit()
            return result
        except Exception:
            self.db.rollback()
            raise
