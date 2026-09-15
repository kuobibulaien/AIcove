"""Loopback-only synthetic dataset and HTTP byte/latency instrumentation."""
import asyncio
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cryptography.fernet import Fernet

temporary = tempfile.TemporaryDirectory(prefix='aicove-sync-benchmark-')
root = Path(temporary.name)
os.environ.update(DATABASE_URL='sqlite:///' + str(root/'sync.db'),
                  SYNC_V3_BLOB_DIR=str(root/'blobs'),
                  SYNC_V3_ENCRYPTION_KEY=Fernet.generate_key().decode(),
                  SECRET_KEY='disposable-local-benchmark-signing-key')
from database import init_db, SessionLocal
from models import User
from auth import get_password_hash
from sync_v3.app import app
from sync_v3.crypto import Vault
from sync_v3.service import SyncEngine
from sync_v3.models import Blob
from sync_v3.contracts import canonical
import uvicorn

count = int(os.environ.get('AICOVE_BENCH_MESSAGES', '10000'))
delay = float(os.environ.get('AICOVE_BENCH_LATENCY_MS', '100')) / 1000
init_db()
with SessionLocal.begin() as db:
    db.add(User(id=1, username='benchmark', unique_id='synthetic-only',
                password_hash=get_password_hash('local-benchmark-password')))

with SessionLocal.begin() as db:
    db.add(User(id=2, username='uploader', unique_id='synthetic-upload-only',
                password_hash=get_password_hash('local-benchmark-password')))

content_hash = hashlib.sha256()
with SessionLocal() as db:
    engine = SyncEngine(db, 1, Vault())
    account = engine._account()
    at = 1789257600000
    for c in range(5):
        engine._write(account, 'conversations', f'c{c}', {'client_schema':16, 'row':{
            'id':f'c{c}', 'title':f'Conversation {c}', 'display_name':f'Conversation {c}',
            'created_at':at, 'updated_at':at}}, [])
    key='aicove.ui_models.v1'
    setting_id=hashlib.sha256(f'preference:{key}'.encode()).hexdigest()
    engine._write(account, 'settings', setting_id, {'storage':'preference','key':key,
                  'json_value':json.dumps({'fontSize':16,'themeMode':'dark'})}, [])
    # Deterministic opaque binary payloads measure transport, not image rendering.
    media=[]
    for i in range(10):
        data=hashlib.sha256(f'fixture-binary-{i}'.encode()).digest()*2048
        digest=hashlib.sha256(data).hexdigest()
        from sync_v3.blobs import BlobStore
        store=BlobStore()
        thumbnail=hashlib.sha256(f'fixture-thumb-{i}'.encode()).digest()*32
        thumbnail_digest=hashlib.sha256(thumbnail).hexdigest()
        for blob_id, content in ((digest,data),(thumbnail_digest,thumbnail)):
            destination=store.path(1,blob_id)
            destination.parent.mkdir(parents=True,exist_ok=True)
            destination.write_bytes(content)
            db.add(Blob(user_id=1,digest=blob_id,size=len(content)))
        asset={'media_version':1,'media_id':digest,'mime_type':'image/png','byte_length':len(data),
               'created_at_ms':at,'last_chat_at_ms':at,'original_required':False,
               'width':128,'height':128,'original_sha256':digest,'original_blob':digest,
               'thumbnail_blob':thumbnail_digest,'locations':[]}
        engine._write(account,'media_assets',digest,asset,[digest,thumbnail_digest])
        media.append(digest)
    for i in range(count):
        mid=f'm{i:06d}'; cid=f'c{i%5}'; created=at-(count-i)*60000
        text=('Synthetic conversation content and tool result. '*8)+' '.join(hashlib.sha256(f'{mid}:{j}'.encode()).hexdigest()[:32] for j in range(20))
        blocks=[{'id':f'b{i}', 'message_id':mid,'type':'mainText','data':json.dumps({'text':text}),
                 'sort_order':0,'created_at':created,'status':'success'}]
        mappings=[{'id':f'p{i}-{j}','conversation_id':cid,'raw_message_id':mid,
                   'projected_message_id':f'view{i}-{j}','projection_kind':'assistant',
                   'projection_version':1,'segment_index':j,'created_at':created} for j in range(2)]
        refs=[media[i%10]] if i>=count-10 else []
        raw=json.dumps({'version':1,'rawReplyText':text,'processedText':text,
                        'toolCalls':[], 'projectedMessages':[{'content':text}],
                        'images':[f'aicove-media://{d}' for d in refs]})
        content_hash.update(canonical({'id':mid,'content':text,'raw':json.loads(raw)}).encode())
        # Model a server upgraded from standalone child records to snapshots.
        for b in blocks: engine._write(account,'message_blocks',b['id'],{'client_schema':16,'row':b},[])
        for m in mappings: engine._write(account,'message_projection_mappings',m['id'],{'client_schema':16,'row':m},[])
        engine._write(account,'messages',mid,{'client_schema':16,'message_snapshot_version':1,
            'row':{'id':mid,'conversation_id':cid,'role':'assistant','content':text,
                   'created_at':created,'raw_payload':raw},
            'message_blocks':blocks,'message_projection_mappings':mappings},[],media_ids=refs)
        if i%250==249: db.commit(); account=engine._account()
    db.commit()

stats=defaultdict(lambda:{'requests':0,'request_body_bytes':0,'response_body_bytes':0,'server_ms':0.0})


class MeasureHTTP:
    def __init__(self, app): self.app=app
    async def __call__(self, scope, receive, send):
        if scope['type']!='http' or '/sync/v3/' not in scope['path']:
            return await self.app(scope,receive,send)
        route='blobs' if '/blobs/' in scope['path'] else scope['path'].rsplit('/',1)[-1]
        stats[route]['requests']+=1
        await asyncio.sleep(delay)
        started=time.perf_counter()
        async def recv():
            msg=await receive()
            stats[route]['request_body_bytes']+=len(msg.get('body',b''))
            return msg
        async def emit(msg):
            if msg['type']=='http.response.body': stats[route]['response_body_bytes']+=len(msg.get('body',b''))
            await send(msg)
        await self.app(scope,recv,emit)
        stats[route]['server_ms']+=round((time.perf_counter()-started)*1000,3)


app.add_middleware(MeasureHTTP)


@app.get('/fixture/metrics')
def metrics():
    return {'messages':count,'legacy_children':count*3,'media_originals':10,'unique_blob_files':20,'content_sha256':content_hash.hexdigest(),
            'injected_request_latency_ms':delay*1000,'routes':dict(stats)}


@app.post('/fixture/reset-metrics')
def reset_metrics():
    stats.clear()
    return {'ok': True}


@app.get('/fixture/upload-state')
def upload_state():
    from sqlalchemy import select
    from sync_v3.models import Entity
    checksum = hashlib.sha256()
    with SessionLocal() as db:
        entities = list(db.scalars(select(Entity).where(Entity.user_id == 2).order_by(Entity.entity_id)))
        message_count = 0
        for entity in entities:
            if entity.kind != 'messages': continue
            row = Vault().open(entity.document)['payload']['row']
            checksum.update(canonical({'id':row['id'],'content':row['content'],
                                       'raw':json.loads(row['raw_payload'])}).encode())
            message_count += 1
        return {'messages':message_count, 'content_sha256':checksum.hexdigest()}


listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(128)
print(f'READY {listener.getsockname()[1]}',flush=True)
try:
    uvicorn.run(app,fd=listener.fileno(),log_level='error',access_log=False)
finally:
    listener.close();temporary.cleanup()
