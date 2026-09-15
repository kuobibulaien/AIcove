"""Account administration for v3; account retirement preserves sync ownership."""
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select, func

from auth import get_current_admin_user
from database import get_db
from models import User
from .contracts import Contract
from .models import Entity, Snapshot

router = APIRouter(prefix='/api/v1/admin', tags=['账号管理'],
                   dependencies=[Depends(get_current_admin_user)])


class ActiveUpdate(Contract):
    is_active: bool


@router.get('/users')
def users(after: int = Query(0, ge=0), limit: int = Query(100, ge=1, le=100), db=Depends(get_db)):
    rows = db.scalars(select(User).where(User.id > after).order_by(User.id).limit(limit + 1)).all()
    records = []
    for user in rows[:limit]:
        counts = dict(db.execute(select(Entity.kind, func.count()).where(
            Entity.user_id == user.id, Entity.deleted.is_(False)).group_by(Entity.kind)).all())
        records.append({**user.to_dict(), 'sync_counts': counts,
                        'snapshot_count': db.scalar(select(func.count()).select_from(Snapshot).where(
                            Snapshot.user_id == user.id))})
    return {'users': records, 'has_more': len(rows) > limit,
            'next_cursor': records[-1]['id'] if records else after}


@router.put('/users/{user_id}/active')
def active(user_id: int, request: ActiveUpdate, admin=Depends(get_current_admin_user), db=Depends(get_db)):
    if user_id == int(admin) and not request.is_active:
        raise HTTPException(409, detail='不能禁用当前登录的管理员')
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(404, detail='账号不存在')
    user.is_active = request.is_active
    db.commit()
    return {'id': user_id, 'is_active': request.is_active}
