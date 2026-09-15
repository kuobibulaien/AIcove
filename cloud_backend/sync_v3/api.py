"""HTTP v3 adapter. All sync endpoints require the existing account login."""
import asyncio
import time

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import FileResponse
from sqlalchemy.orm import Session

from auth import get_current_user
from database import get_db
from .blobs import BlobStore
from .contracts import Push, Restore, SnapshotCreate, BlobInventory
from .crypto import Vault
from .service import SyncEngine, SyncError

router = APIRouter(prefix='/api/v1/sync/v3', tags=['云同步 v3'])


def get_engine(user: int = Depends(get_current_user), db: Session = Depends(get_db)):
    try:
        vault = Vault()
    except (RuntimeError, ValueError):
        raise HTTPException(503, detail={'code': 'sync_not_configured', 'message': '服务器尚未配置云同步加密密钥'})
    return SyncEngine(db, user, vault)


def invoke(method, *args, **kwargs):
    try:
        return method(*args, **kwargs)
    except SyncError as error:
        raise HTTPException(error.status, detail={'code': error.code, 'message': error.message})


@router.get('/status')
def status(engine=Depends(get_engine)):
    return invoke(engine.status)


@router.post('/push')
def push(request: Push, engine=Depends(get_engine)):
    return invoke(engine.push, request)


@router.get('/pull')
def pull(epoch: str, after: int = Query(0, ge=0), limit: int = Query(100, ge=1, le=100),
         through: int = Query(None, ge=0), engine=Depends(get_engine)):
    return invoke(engine.pull, epoch, after, limit, through)


@router.get('/read')
def read(epoch: str, after: int = Query(0, ge=0), limit: int = Query(512, ge=1, le=512),
         through: int = Query(None, ge=0), stage: str = 'delta', engine=Depends(get_engine)):
    return invoke(engine.read_page, epoch, after, limit, through, stage)


@router.post('/missing-blobs')
def missing_blobs(request: BlobInventory, engine=Depends(get_engine)):
    return invoke(engine.missing_blobs, request.digests)


@router.get('/wait')
async def wait(epoch: str, after: int = Query(0, ge=0), timeout: int = Query(25, ge=0, le=25),
               engine=Depends(get_engine)):
    # Durable DB state is the notification source, also across worker processes.
    # Release transactions between waits so idle clients never hold DB locks.
    deadline = time.monotonic() + timeout
    while True:
        page = invoke(engine.pull, epoch, after, 1)
        engine.db.rollback()
        if page['through'] > after or time.monotonic() >= deadline:
            return {'cursor': page['through'], 'epoch': page['epoch']}
        await asyncio.sleep(min(0.5, max(0, deadline - time.monotonic())))


@router.get('/bootstrap')
def bootstrap(epoch: str, after: int = Query(0, ge=0), limit: int = Query(100, ge=1, le=100),
              through: int = Query(None, ge=0), engine=Depends(get_engine)):
    return invoke(engine.bootstrap, epoch, after, limit, through)


@router.get('/conflicts')
def conflicts(engine=Depends(get_engine)):
    return {'conflicts': invoke(engine.conflicts)}


@router.post('/conflicts/{conflict_id}/resolve')
def resolve(conflict_id: str, request: Restore, use_incoming: bool = False,
            engine=Depends(get_engine)):
    return invoke(engine.resolve, conflict_id, request, use_incoming)


@router.put('/blobs/batch')
async def upload_batch(request: Request, engine=Depends(get_engine)):
    try:
        return await BlobStore().upload_batch(engine, request.stream())
    except SyncError as error:
        raise HTTPException(error.status, detail={'code': error.code, 'message': error.message})


@router.put('/blobs/{digest}')
async def upload(digest: str, request: Request, engine=Depends(get_engine)):
    try:
        return await BlobStore().upload(engine, digest, request.stream())
    except SyncError as error:
        raise HTTPException(error.status, detail={'code': error.code, 'message': error.message})


@router.get('/blobs/{digest}')
def download(digest: str, engine=Depends(get_engine)):
    path = invoke(BlobStore().download, engine, digest)
    return FileResponse(path, media_type='application/octet-stream', filename=digest)


@router.post('/snapshots')
def create_snapshot(request: SnapshotCreate, engine=Depends(get_engine)):
    return invoke(engine.create_snapshot, request.name)


@router.get('/snapshots')
def snapshots(engine=Depends(get_engine)):
    return {'snapshots': invoke(engine.snapshots)}


@router.get('/snapshots/{snapshot_id}')
def snapshot(snapshot_id: str, after: int = Query(0, ge=0), limit: int = Query(100, ge=1, le=100),
             engine=Depends(get_engine)):
    return invoke(engine.snapshot, snapshot_id, after, limit)


@router.post('/snapshots/{snapshot_id}/restore')
def restore(snapshot_id: str, request: Restore, engine=Depends(get_engine)):
    return invoke(engine.restore, snapshot_id, request)
