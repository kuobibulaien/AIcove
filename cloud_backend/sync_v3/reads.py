"""Indexed current-state delivery; immutable history remains the backup source."""
from sqlalchemy import select, func, and_, or_, insert, tuple_
from .contracts import canonical
from .models import Change, ReadEntry

HEAD_KINDS = {'settings', 'plugin_presets', 'providers', 'conversations', 'contact_memory'}
CHILDREN = {'message_blocks', 'message_projection_mappings'}
PAGE_BYTES = 1024 * 1024


def index_document(user, document):
    payload = document['payload']
    row = payload.get('row') or {}
    kind = document['kind']
    at = row.get('created_at', 0)
    if not isinstance(at, (int, float)):
        at = 0
    if 0 < at < 100000000000:
        at *= 1000
    owner = row.get({'messages': 'conversation_id', 'message_blocks': 'message_id',
                     'message_projection_mappings': 'raw_message_id'}.get(kind, ''))
    return dict(user_id=user, seq=document['seq'], kind=kind,
                entity_id=document['entity_id'], owner_id=owner, created_at=int(at),
                hidden=bool(document['deleted'] or row.get('deleted_at')),
                message_snapshot=payload.get('message_snapshot_version') == 1)


def backfill_read_index(db, vault):
    """Resumable additive migration, including writes made by an older server."""
    while True:
        rows = db.execute(select(Change.user_id, Change.document).outerjoin(
            ReadEntry, and_(ReadEntry.user_id == Change.user_id, ReadEntry.seq == Change.seq)
        ).where(ReadEntry.seq.is_(None)).order_by(Change.user_id, Change.seq).limit(500)).all()
        if not rows:
            db.rollback()
            return
        dialect = db.get_bind().dialect.name
        if dialect == 'sqlite':
            from sqlalchemy.dialects.sqlite import insert as index_insert
        elif dialect == 'postgresql':
            from sqlalchemy.dialects.postgresql import insert as index_insert
        else:
            index_insert = insert
        statement = index_insert(ReadEntry)
        if dialect in ('sqlite', 'postgresql'):
            statement = statement.on_conflict_do_nothing(index_elements=['user_id', 'seq'])
        db.execute(statement, [index_document(user, vault.open(doc)) for user, doc in rows])
        db.commit()


def document_references(document):
    wanted = {('media_assets', m) for m in document.get('media_ids', [])}
    row = document['payload'].get('row') or {}
    if document['kind'] == 'messages' and row.get('conversation_id'):
        wanted.add(('conversations', row['conversation_id']))
    owner_key = {'message_blocks':'message_id','message_projection_mappings':'raw_message_id'}.get(document['kind'])
    if owner_key and row.get(owner_key):
        wanted.add(('messages', row[owner_key]))
    return wanted


def read_page(engine, boundary, after, stage, limit):
    db, user = engine.db, engine.user
    latest_seq = select(func.max(ReadEntry.seq).label('seq')).where(
        ReadEntry.user_id == user, ReadEntry.seq <= boundary
    ).group_by(ReadEntry.kind, ReadEntry.entity_id).subquery()
    latest = select(ReadEntry).where(ReadEntry.user_id == user,
                                    ReadEntry.seq.in_(select(latest_seq.c.seq))).cte('latest')
    parent = latest.alias('parent')
    snapshot_parents = select(parent.c.entity_id).where(
        parent.c.kind == 'messages', parent.c.message_snapshot.is_(True))
    # Materialize the owner set once. A correlated lookup per historical child
    # turns a small paged read into tens of thousands of index probes.
    valid = ~and_(latest.c.kind.in_(CHILDREN), latest.c.owner_id.is_not(None),
                  latest.c.owner_id.in_(snapshot_parents))
    if stage != 'delta':
        ranked = select(latest.c.seq, func.row_number().over(
            partition_by=latest.c.owner_id,
            order_by=(latest.c.created_at.desc(), latest.c.entity_id.desc())
        ).label('position')).where(latest.c.kind == 'messages', latest.c.hidden.is_(False)).subquery()
        recent = select(ranked.c.seq).where(ranked.c.position <= 50)
        head = or_(latest.c.kind.in_(HEAD_KINDS), latest.c.seq.in_(recent))
        valid = and_(valid, head if stage == 'head' else ~head)
    query = select(latest.c.seq).where(valid, latest.c.seq > after).order_by(latest.c.seq).limit(limit+1)
    seqs = list(db.scalars(query))
    candidates, references, size = [], {}, 0
    more = len(seqs) > limit
    query = select(Change).where(Change.user_id == user, Change.seq.in_(seqs[:limit])).order_by(Change.seq)
    for change in db.scalars(query).yield_per(1):
        document = engine.vault.open(change.document)
        addition = len(canonical(document).encode())
        if candidates and size + addition > PAGE_BYTES:
            more = True
            break
        candidates.append(document)
        wanted = document_references(document)
        references[document['seq']] = wanted
        size += addition
    wanted = sorted(set().union(*references.values())) if references else []
    available = {}
    dependency_bytes = 0
    seen = set()
    for depth in range(3):
        descendants = set()
        seen.update(wanted)
        for start in range(0, len(wanted), 300):
            dependency_query = select(Change).join(latest, and_(
                Change.user_id == user, Change.seq == latest.c.seq
            )).where(tuple_(latest.c.kind, latest.c.entity_id).in_(wanted[start:start+300]))
            for change in db.scalars(dependency_query).yield_per(1):
                dependency = engine.vault.open(change.document)
                dependency_bytes += len(canonical(dependency).encode())
                if dependency_bytes > 16 * 1024 * 1024:
                    from .service import SyncError
                    raise SyncError('dependency_page_too_large', '附件身份资料过大，请缩小读取批次', 413)
                available[(change.kind, change.entity_id)] = dependency
                descendants.update(document_references(dependency))
        wanted = sorted(descendants - seen)
        if not wanted: break
    docs, dependencies, size = [], {}, 0
    for document in candidates:
        needed = set(references[document['seq']])
        for _ in range(3):
            needed.update(set().union(*(document_references(available[k]) for k in list(needed) if k in available)))
        extra = {available[key]['seq']: available[key] for key in needed
                 if key in available and available[key]['seq'] not in dependencies}
        addition = len(canonical(document).encode()) + sum(len(canonical(d).encode()) for d in extra.values())
        if docs and size + addition > PAGE_BYTES:
            more = True
            break
        docs.append(document)
        dependencies.update(extra)
        size += addition
    main_seqs = {d['seq'] for d in docs}
    return {'epoch': engine._account().epoch, 'through': boundary,
            'next_cursor': docs[-1]['seq'] if more else boundary, 'has_more': more,
            'documents': docs, 'dependencies': [d for s, d in dependencies.items() if s not in main_seqs]}
