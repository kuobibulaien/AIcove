"""Offline administration and portable, verified account snapshots.

Run from cloud_backend: python -m sync_v3 --help
Secrets come from the environment or a password prompt, never command arguments.
"""
import argparse
import getpass
import hashlib
import os
import tempfile
import uuid
import zipfile
import secrets
from pathlib import Path

from sqlalchemy import select

from auth import get_password_hash
from database import init_db, SessionLocal
from models import User
from .blobs import BlobStore, MAX_BLOB_BYTES
from .crypto import Vault
from .models import Blob, Entity
from .service import SyncEngine, SyncError
from .initialization import validate_installation


def export_snapshot(engine, snapshot_id, output, blobs):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.backup-', dir=output.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            page_index, digests, count = [], set(), 0
            manifest = {}
            for index, page in enumerate(engine.snapshot_pages(snapshot_id)):
                name = f'pages/{index:08}.enc'
                encoded = engine.vault.seal(page).encode()
                archive.writestr(name, encoded)
                page_index.append({'name': name, 'sha256': hashlib.sha256(encoded).hexdigest()})
                digests.update(page['blob_ids'])
                count += len(page['entities'])
                manifest = {key: page[key] for key in ('protocol_version', 'epoch', 'cursor')}
            manifest.update(archive_revision=1, pages=page_index, blob_ids=sorted(digests))
            archive.writestr('manifest.enc', engine.vault.seal(manifest))
            for digest in manifest['blob_ids']:
                path = blobs.download(engine, digest)
                with path.open('rb') as source:
                    checksum = hashlib.sha256()
                    with archive.open('blobs/' + digest, 'w', force_zip64=True) as target:
                        while chunk := source.read(1024 * 1024):
                            checksum.update(chunk)
                            target.write(chunk)
                    if checksum.hexdigest() != digest:
                        raise SyncError('corrupt_blob', '附件损坏，备份未完成')
        # Refuse to replace an existing user backup. Same-filesystem link is atomic.
        os.link(temporary, output)
        return {'snapshot_id': snapshot_id, 'entities': count,
                'attachments': len(manifest['blob_ids'])}
    finally:
        Path(temporary).unlink(missing_ok=True)


def import_archive(engine, source, blobs):
    """Import into an empty account only. Existing accounts use snapshot restore."""
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)) or 'manifest.enc' not in names:
            raise SyncError('invalid_archive', '备份目录无效', 422)
        if archive.getinfo('manifest.enc').file_size > 256 * 1024 * 1024:
            raise SyncError('invalid_archive', '备份清单过大', 422)
        manifest = engine.vault.open(archive.read('manifest.enc').decode())
        if manifest.get('protocol_version') != 3 or manifest.get('archive_revision') != 1:
            raise SyncError('invalid_archive', '不兼容的备份版本', 422)
        pages = manifest['pages']
        if not pages or any(p['name'] != f'pages/{i:08}.enc' for i, p in enumerate(pages)):
            raise SyncError('invalid_archive', '备份分页目录无效', 422)
        expected = {'manifest.enc'} | {'blobs/' + b for b in manifest['blob_ids']} | {p['name'] for p in pages}
        if set(names) != expected:
            raise SyncError('invalid_archive', '备份附件清单不匹配', 422)
        # Verify all bytes before touching account rows. Files left by an
        # interrupted import are unreferenced and cannot be downloaded.
        verified = []
        for digest in manifest['blob_ids']:
            target = blobs.path(engine.user, digest)
            entry = archive.getinfo('blobs/' + digest)
            if entry.file_size > MAX_BLOB_BYTES:
                raise SyncError('blob_too_large', '备份附件过大', 422)
            target.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix='.restore-', dir=target.parent)
            checksum = hashlib.sha256()
            try:
                with os.fdopen(fd, 'wb') as output, archive.open(entry) as source_file:
                    while chunk := source_file.read(1024 * 1024):
                        checksum.update(chunk)
                        output.write(chunk)
                    output.flush()
                    os.fsync(output.fileno())
                if checksum.hexdigest() != digest:
                    raise SyncError('corrupt_blob', '备份附件校验失败', 422)
                os.replace(temporary, target)
                verified.append((digest, entry.file_size))
            finally:
                Path(temporary).unlink(missing_ok=True)
    def documents():
        with zipfile.ZipFile(source) as archive:
            for page_info in pages:
                entry = archive.getinfo(page_info['name'])
                if entry.file_size > 24 * 1024 * 1024:
                    raise SyncError('invalid_archive', '备份分页过大', 422)
                encoded = archive.read(entry)
                if hashlib.sha256(encoded).hexdigest() != page_info['sha256']:
                    raise SyncError('invalid_archive', '备份分页校验失败', 422)
                page = engine.vault.open(encoded.decode())
                if page['epoch'] != manifest['epoch'] or page['cursor'] != manifest['cursor']:
                    raise SyncError('invalid_archive', '备份分页不属于同一快照', 422)
                yield from page['entities']
    try:
        account = engine._account(lock=True)
        if account.cursor or engine.db.scalar(select(Entity).where(Entity.user_id == engine.user).limit(1)):
            raise SyncError('account_not_empty', '只能导入到空账号，已有数据请使用快照恢复')
        from .contracts import KINDS, Mutation
        seen, previous_seq = set(), 0
        allowed_blobs = set(manifest['blob_ids'])
        for document in documents():
            key = (document['kind'], document['entity_id'])
            if key in seen or key[0] not in KINDS | {'_conflicts'}:
                raise SyncError('invalid_archive', '备份实体无效或重复', 422)
            if document['payload_version'] != 1 or not isinstance(document['deleted'], bool):
                raise SyncError('invalid_archive', '备份实体版本或状态无效', 422)
            if not previous_seq < document['seq'] <= manifest['cursor']:
                raise SyncError('invalid_archive', '备份实体顺序无效', 422)
            previous_seq = document['seq']
            if key[0] != '_conflicts':
                Mutation(op_id='validate', kind=key[0], entity_id=key[1], base_version=0,
                         payload=document['payload'], blob_ids=document['blob_ids'], media_ids=document.get('media_ids', []))
            seen.add(key)
            if not set(document['blob_ids']) <= allowed_blobs:
                raise SyncError('invalid_archive', '实体引用未备份的附件', 422)
        for digest, size in verified:
            if engine.db.get(Blob, (engine.user, digest)) is None:
                engine.db.add(Blob(user_id=engine.user, digest=digest, size=size))
        account.epoch = str(uuid.uuid4())
        for document in documents():
            engine._write(account, document['kind'], document['entity_id'], document['payload'],
                          document['blob_ids'], document['deleted'], document.get('media_ids', []))
        result = {'entities': len(seen), 'attachments': len(verified), 'epoch': account.epoch}
        engine.db.commit()
        return result
    except Exception:
        engine.db.rollback()
        raise



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    config = commands.add_parser('init-config')
    config.add_argument('--file', default='.env')
    create = commands.add_parser('create-user')
    create.add_argument('--username', required=True)
    create.add_argument('--admin', action='store_true')
    create.add_argument('--allow-short-password', action='store_true',
                        help='Explicitly allow a 6 or 7 byte password for this account')
    for command in ('backup', 'restore'):
        sub = commands.add_parser(command)
        sub.add_argument('--user-id', type=int, required=True)
        sub.add_argument('--file', required=True)
    args = parser.parse_args()
    if args.command == 'init-config':
        from cryptography.fernet import Fernet
        with os.fdopen(os.open(args.file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as output:
            output.write('SECRET_KEY=' + secrets.token_urlsafe(48) + '\n')
            output.write('SYNC_V3_ENCRYPTION_KEY=' + Fernet.generate_key().decode() + '\n')
            output.write('DATABASE_URL=sqlite:///./data/sync.db\n')
            output.write('SYNC_V3_BLOB_DIR=./data/sync3-blobs\nALLOWED_ORIGINS=\n')
            output.flush()
            os.fsync(output.fileno())
        print('Created server configuration; existing files are never replaced')
        return
    init_db()
    with SessionLocal() as db:
        if args.command == 'create-user':
            if db.scalar(select(User).where(User.username == args.username)):
                parser.error('Username already exists')
            password = getpass.getpass('Password: ')
            if password != getpass.getpass('Repeat password: '):
                parser.error('Passwords do not match')
            from uuid import uuid4
            user = User(username=args.username, unique_id=str(uuid4()),
                        password_hash=get_password_hash(password, minimum_bytes=6 if args.allow_short_password else 8),
                        is_admin=args.admin)
            db.add(user)
            db.commit()
            print(f'Created user {user.id}')
            return
        if db.get(User, args.user_id) is None:
            parser.error('User does not exist')
        vault = Vault()
        validate_installation(db, vault)
        engine = SyncEngine(db, args.user_id, vault)
        if args.command == 'backup':
            snapshot = engine.create_snapshot('Server backup')
            result = export_snapshot(engine, snapshot['snapshot_id'], args.file, BlobStore())
        else:
            result = import_archive(engine, args.file, BlobStore())
        # Only aggregate counts, never payloads, usernames, credentials or keys.
        print({key: value for key, value in result.items() if key in ('entities', 'attachments')})


if __name__ == '__main__':
    main()
