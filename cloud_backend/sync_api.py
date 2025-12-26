"""数据同步API"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from sqlalchemy import desc
from typing import List, Optional
from pydantic import BaseModel
from datetime import datetime
import json

from database import get_db
from auth import get_current_user
from models import Contact, Message, UserSettings

router = APIRouter()


# ============ Pydantic模型 ============

class ContactSync(BaseModel):
    contact_id: str
    name: str
    avatar_url: Optional[str] = None
    character_data: Optional[dict] = None
    updated_at: str
    is_deleted: bool = False


class MessageSync(BaseModel):
    message_id: str
    contact_id: str
    role: str
    content: str
    metadata: Optional[dict] = None
    created_at: str
    is_deleted: bool = False


class ContactBatchRequest(BaseModel):
    items: List[ContactSync]


class MessageBatchRequest(BaseModel):
    items: List[MessageSync]


class SettingsUpdateRequest(BaseModel):
    settings: dict


# ============ 联系人同步 ============

@router.get("/contacts")
async def get_contacts(
    since: Optional[str] = None,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取用户所有联系人（支持增量同步）"""
    query = db.query(Contact).filter(Contact.user_id == user_id)
    
    # 增量同步：只返回指定时间之后更新的
    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
            query = query.filter(Contact.updated_at > since_dt)
        except:
            pass
    
    contacts = query.order_by(Contact.updated_at).all()
    
    return {
        "contacts": [c.to_dict() for c in contacts],
        "count": len(contacts),
        "server_time": datetime.utcnow().isoformat() + "Z"
    }


@router.post("/contacts")
async def sync_contacts(
    request: ContactBatchRequest,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """批量上传/更新联系人"""
    synced = 0
    conflicts = []
    errors = []
    
    for item in request.items:
        try:
            # 解析客户端时间戳
            client_updated_at = datetime.fromisoformat(item.updated_at.replace('Z', '+00:00'))
            
            # 检查是否已存在
            existing = db.query(Contact).filter(
                Contact.user_id == user_id,
                Contact.contact_id == item.contact_id
            ).first()
            
            if existing:
                # 冲突检测：服务器版本更新
                if existing.updated_at and existing.updated_at > client_updated_at:
                    conflicts.append({
                        "contact_id": item.contact_id,
                        "reason": "服务器版本更新",
                        "server_version": existing.to_dict(),
                        "client_version": item.dict()
                    })
                    continue
                
                # 更新现有联系人
                existing.name = item.name
                existing.avatar_url = item.avatar_url
                existing.character_data = json.dumps(item.character_data) if item.character_data else None
                existing.is_deleted = item.is_deleted
                existing.updated_at = datetime.utcnow()
            else:
                # 创建新联系人
                new_contact = Contact(
                    user_id=user_id,
                    contact_id=item.contact_id,
                    name=item.name,
                    avatar_url=item.avatar_url,
                    character_data=json.dumps(item.character_data) if item.character_data else None,
                    is_deleted=item.is_deleted
                )
                db.add(new_contact)
            
            synced += 1
        except Exception as e:
            errors.append({
                "contact_id": item.contact_id,
                "error": str(e)
            })
    
    db.commit()
    
    return {
        "synced": synced,
        "conflicts": conflicts,
        "errors": errors,
        "server_time": datetime.utcnow().isoformat() + "Z"
    }


@router.delete("/contacts/{contact_id}")
async def delete_contact(
    contact_id: str,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """删除联系人（软删除）"""
    contact = db.query(Contact).filter(
        Contact.user_id == user_id,
        Contact.contact_id == contact_id
    ).first()
    
    if not contact:
        raise HTTPException(status_code=404, detail="联系人不存在")
    
    contact.is_deleted = True
    contact.updated_at = datetime.utcnow()
    db.commit()
    
    return {"status": "ok", "message": "联系人已删除"}


# ============ 消息同步 ============

@router.get("/messages")
async def get_messages(
    contact_id: Optional[str] = None,
    since: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取消息（支持增量同步、分页）"""
    query = db.query(Message).filter(Message.user_id == user_id)
    
    # 按联系人筛选
    if contact_id:
        query = query.filter(Message.contact_id == contact_id)
    
    # 增量同步
    if since:
        try:
            since_dt = datetime.fromisoformat(since.replace('Z', '+00:00'))
            query = query.filter(Message.created_at > since_dt)
        except:
            pass
    
    # 分页
    total = query.count()
    messages = query.order_by(Message.created_at).offset(offset).limit(limit).all()
    
    return {
        "messages": [m.to_dict() for m in messages],
        "count": len(messages),
        "total": total,
        "has_more": (offset + len(messages)) < total,
        "server_time": datetime.utcnow().isoformat() + "Z"
    }


@router.post("/messages")
async def sync_messages(
    request: MessageBatchRequest,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """批量上传消息"""
    synced = 0
    skipped = 0
    errors = []
    
    for item in request.items:
        try:
            # 检查是否已存在（避免重复）
            existing = db.query(Message).filter(
                Message.message_id == item.message_id
            ).first()
            
            if existing:
                skipped += 1
                continue
            
            # 解析时间戳
            created_at = datetime.fromisoformat(item.created_at.replace('Z', '+00:00'))
            
            # 创建新消息
            new_message = Message(
                user_id=user_id,
                message_id=item.message_id,
                contact_id=item.contact_id,
                role=item.role,
                content=item.content,
                metadata=json.dumps(item.metadata) if item.metadata else None,
                is_deleted=item.is_deleted,
                created_at=created_at
            )
            db.add(new_message)
            synced += 1
        except Exception as e:
            errors.append({
                "message_id": item.message_id,
                "error": str(e)
            })
    
    db.commit()
    
    return {
        "synced": synced,
        "skipped": skipped,
        "errors": errors,
        "server_time": datetime.utcnow().isoformat() + "Z"
    }


@router.delete("/messages/{message_id}")
async def delete_message(
    message_id: str,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """删除消息（软删除）"""
    message = db.query(Message).filter(
        Message.user_id == user_id,
        Message.message_id == message_id
    ).first()
    
    if not message:
        raise HTTPException(status_code=404, detail="消息不存在")
    
    message.is_deleted = True
    db.commit()
    
    return {"status": "ok", "message": "消息已删除"}


# ============ 用户设置同步 ============

@router.get("/settings")
async def get_settings(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取用户设置"""
    user_settings = db.query(UserSettings).filter(
        UserSettings.user_id == user_id
    ).first()
    
    if not user_settings:
        return {
            "settings": {},
            "updated_at": None
        }
    
    return user_settings.to_dict()


@router.put("/settings")
async def update_settings(
    request: SettingsUpdateRequest,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """更新用户设置"""
    user_settings = db.query(UserSettings).filter(
        UserSettings.user_id == user_id
    ).first()
    
    if user_settings:
        user_settings.settings_json = json.dumps(request.settings)
        user_settings.updated_at = datetime.utcnow()
    else:
        user_settings = UserSettings(
            user_id=user_id,
            settings_json=json.dumps(request.settings)
        )
        db.add(user_settings)
    
    db.commit()
    db.refresh(user_settings)
    
    return user_settings.to_dict()


# ============ 同步状态 ============

@router.get("/status")
async def sync_status(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取同步状态概览"""
    # 联系人统计
    contacts_query = db.query(Contact).filter(
        Contact.user_id == user_id,
        Contact.is_deleted == False
    )
    contacts_count = contacts_query.count()
    latest_contact = contacts_query.order_by(desc(Contact.updated_at)).first()
    
    # 消息统计
    messages_query = db.query(Message).filter(
        Message.user_id == user_id,
        Message.is_deleted == False
    )
    messages_count = messages_query.count()
    latest_message = messages_query.order_by(desc(Message.created_at)).first()
    
    # 设置
    settings = db.query(UserSettings).filter(
        UserSettings.user_id == user_id
    ).first()
    
    return {
        "contacts": {
            "count": contacts_count,
            "last_updated": latest_contact.updated_at.isoformat() + "Z" if latest_contact and latest_contact.updated_at else None
        },
        "messages": {
            "count": messages_count,
            "last_updated": latest_message.created_at.isoformat() + "Z" if latest_message and latest_message.created_at else None
        },
        "settings": {
            "last_updated": settings.updated_at.isoformat() + "Z" if settings and settings.updated_at else None
        },
        "server_time": datetime.utcnow().isoformat() + "Z"
    }
