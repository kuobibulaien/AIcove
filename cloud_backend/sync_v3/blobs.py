"""Account-scoped immutable attachments; publish only verified complete files."""
import hashlib
import os
import tempfile
import zipfile
from pathlib import Path

from .models import Blob
from .service import SyncError

MAX_BLOB_BYTES = 128 * 1024 * 1024
MAX_BATCH_BYTES = 16 * 1024 * 1024
MAX_BATCH_FILES = 64


class BlobStore:
    def __init__(self, root=None):
        self.root = Path(root or os.getenv('SYNC_V3_BLOB_DIR', 'data/sync3-blobs')).resolve()

    def path(self, user, digest):
        if len(digest) != 64 or any(c not in '0123456789abcdef' for c in digest):
            raise SyncError('invalid_digest', '附件标识无效', 422)
        return self.root / str(int(user)) / digest

    async def upload(self, engine, digest, chunks):
        target = self.path(engine.user, digest)
        target.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix='.upload-', dir=target.parent)
        size, checksum = 0, hashlib.sha256()
        try:
            with os.fdopen(fd, 'wb') as output:
                async for chunk in chunks:
                    size += len(chunk)
                    if size > MAX_BLOB_BYTES:
                        raise SyncError('blob_too_large', '附件超过 128 MiB', 413)
                    checksum.update(chunk)
                    output.write(chunk)
                output.flush()
                os.fsync(output.fileno())
            if checksum.hexdigest() != digest:
                raise SyncError('digest_mismatch', '附件校验失败', 422)
            # Same digest means same bytes; replacing a complete file is safe.
            os.replace(temporary, target)
            engine._account(lock=True)
            row = engine.db.get(Blob, (engine.user, digest))
            if row is None:
                engine.db.add(Blob(user_id=engine.user, digest=digest, size=size))
            engine.db.commit()
            return {'digest': digest, 'size': size}
        except BaseException:
            engine.db.rollback()
            raise
        finally:
            Path(temporary).unlink(missing_ok=True)

    async def upload_batch(self, engine, chunks):
        directory = self.root / str(int(engine.user))
        directory.mkdir(parents=True, exist_ok=True)
        # Archive and extracted files stay private until every digest is valid.
        with tempfile.TemporaryDirectory(prefix='.batch-', dir=directory) as temporary:
            archive_path = Path(temporary) / 'archive.zip'
            size = 0
            with archive_path.open('wb') as output:
                async for chunk in chunks:
                    size += len(chunk)
                    if size > MAX_BATCH_BYTES + 1024 * 1024:
                        raise SyncError('batch_too_large', '附件批次超过大小限制', 413)
                    output.write(chunk)
            verified = []
            try:
                with zipfile.ZipFile(archive_path) as archive:
                    entries = archive.infolist()
                    if not entries or len(entries) > MAX_BATCH_FILES or sum(e.file_size for e in entries) > MAX_BATCH_BYTES:
                        raise SyncError('batch_too_large', '附件批次超过数量或大小限制', 413)
                    seen = set()
                    for entry in entries:
                        target = self.path(engine.user, entry.filename)
                        if entry.filename in seen or entry.is_dir() or entry.flag_bits & 1:
                            raise SyncError('invalid_batch', '附件批次格式无效', 422)
                        seen.add(entry.filename)
                        extracted = Path(temporary) / entry.filename
                        checksum, length = hashlib.sha256(), 0
                        with archive.open(entry) as source, extracted.open('wb') as output:
                            while chunk := source.read(64 * 1024):
                                length += len(chunk)
                                if length > entry.file_size or length > MAX_BATCH_BYTES:
                                    raise SyncError('batch_too_large', '附件批次超过大小限制', 413)
                                checksum.update(chunk)
                                output.write(chunk)
                            output.flush()
                            os.fsync(output.fileno())
                        if length != entry.file_size or checksum.hexdigest() != entry.filename:
                            raise SyncError('digest_mismatch', '附件校验失败', 422)
                        verified.append((entry.filename, length, extracted, target))
                engine._account(lock=True)
                for digest, length, extracted, target in verified:
                    os.replace(extracted, target)
                    if engine.db.get(Blob, (engine.user, digest)) is None:
                        engine.db.add(Blob(user_id=engine.user, digest=digest, size=length))
                engine.db.commit()
                return {'blobs': [{'digest': digest, 'size': length} for digest, length, _, _ in verified]}
            except (zipfile.BadZipFile, RuntimeError, NotImplementedError, ValueError, EOFError):
                engine.db.rollback()
                raise SyncError('invalid_batch', '附件批次格式或校验无效', 422)
            except BaseException:
                engine.db.rollback()
                raise

    def download(self, engine, digest):
        path = self.path(engine.user, digest)
        row = engine.db.get(Blob, (engine.user, digest))
        if row is None or not path.is_file() or path.stat().st_size != row.size:
            raise SyncError('missing_blob', '附件不存在或不完整', 404)
        return path
