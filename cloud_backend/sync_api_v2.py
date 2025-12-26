"""云同步 API v2（施工手册定义）

实现：
- Scope 管理（全局一份）
- 增量同步 pull/push
- 回收站（软删除 + 7天清理 + restore）
- 重生成覆盖（原子事务）
- 分支会话（fork）
- 幂等操作（op_id）
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from sqlalchemy import and_, or_
from typing import List, Optional
from pydantic import BaseModel
from datetime import datetime
import json
import time

from database import get_db
from auth import get_current_user
from models import (
    SyncScope, Conversation, SyncMessage, MessageBlock,
    Provider, SyncOperation, SyncCursor
)
from encryption import encrypt_api_keys, decrypt_api_keys

router = APIRouter(prefix="/v2")

# 回收站保留天数
RECYCLE_BIN_DAYS = 7
RECYCLE_BIN_MS = RECYCLE_BIN_DAYS * 24 * 60 * 60 * 1000


def now_ms() -> int:
    return int(time.time() * 1000)


# ============ Pydantic 模型 ============

class ScopesUpdate(BaseModel):
    enabled_scopes: List[str]


class ConversationCreate(BaseModel):
    id: str
    title: str
    display_name: str
    avatar_url: Optional[str] = None
    character_image: Optional[str] = None
    self_address: Optional[str] = None
    address_user: Optional[str] = None
    voice_file: Optional[str] = None
    persona_prompt: str = ''
    default_provider: Optional[str] = None
    session_provider: Optional[str] = None
    is_pinned: bool = False
    is_favorite: bool = False
    is_muted: bool = False
    notification_sound: bool = True
    parent_conversation_id: Optional[str] = None
    fork_from_message_id: Optional[str] = None


class MessageCreate(BaseModel):
    id: str
    conversation_id: str
    role: str
    content: str
    status: str = 'sent'
    blocks: Optional[List[dict]] = None


class BlockCreate(BaseModel):
    id: str
    type: str
    status: str = 'success'
    data: dict
    sort_order: int = 0


class ProviderCreate(BaseModel):
    id: str
    display_name: str
    api_base_url: str
    enabled: bool = True
    capabilities: List[str] = []
    custom_config: dict = {}
    model_type: Optional[str] = None
    visible_models: List[str] = []
    hidden_models: List[str] = []
    api_keys: List[str] = []


class PushOperation(BaseModel):
    op_id: str
    device_id: str
    op_type: str  # 'upsert_conversation', 'append_message', 'delete', 'restore', 'regen', 'fork', 'upsert_provider'
    data: dict


class PushRequest(BaseModel):
    operations: List[PushOperation]


# ============ Scope 管理 ============

@router.get("/scopes")
async def get_scopes(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取用户同步范围配置"""
    scope = db.query(SyncScope).filter(SyncScope.user_id == user_id).first()
    if not scope:
        # 返回默认值
        return {
            "enabled_scopes": ["chat.history", "characters.cards"],
            "updated_at": now_ms()
        }
    return scope.to_dict()


@router.put("/scopes")
async def update_scopes(
    request: ScopesUpdate,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """更新用户同步范围配置"""
    # 白名单校验
    valid_scopes = {
        "chat.history", "characters.cards", "characters.per_settings",
        "providers.config", "providers.keys", "user.text_inputs"
    }
    for s in request.enabled_scopes:
        if s not in valid_scopes:
            raise HTTPException(400, f"无效的 scope: {s}")

    scope = db.query(SyncScope).filter(SyncScope.user_id == user_id).first()
    ts = now_ms()

    if scope:
        scope.enabled_scopes = json.dumps(request.enabled_scopes)
        scope.updated_at = ts
    else:
        scope = SyncScope(
            user_id=user_id,
            enabled_scopes=json.dumps(request.enabled_scopes),
            updated_at=ts
        )
        db.add(scope)

    db.commit()
    return scope.to_dict()


# ============ 增量拉取 ============

@router.get("/pull")
async def pull_changes(
    device_id: str,
    conversations_since: int = 0,
    messages_since: int = 0,
    providers_since: int = 0,
    include_deleted: bool = True,
    limit: int = 100,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """增量拉取所有变化的数据"""
    # 获取 scope
    scope_record = db.query(SyncScope).filter(SyncScope.user_id == user_id).first()
    enabled_scopes = ["chat.history", "characters.cards"]
    if scope_record:
        try:
            enabled_scopes = json.loads(scope_record.enabled_scopes)
        except:
            pass

    result = {
        "conversations": [],
        "messages": [],
        "providers": [],
        "server_time": now_ms()
    }

    # 拉取会话
    if "chat.history" in enabled_scopes or "characters.cards" in enabled_scopes:
        conv_query = db.query(Conversation).filter(
            Conversation.user_id == user_id,
            Conversation.updated_at > conversations_since
        ).order_by(Conversation.updated_at).limit(limit)

        for conv in conv_query.all():
            d = conv.to_dict(include_deleted=include_deleted)
            if d:
                result["conversations"].append(d)

    # 拉取消息
    if "chat.history" in enabled_scopes:
        msg_query = db.query(SyncMessage).filter(
            SyncMessage.user_id == user_id,
            SyncMessage.created_at > messages_since
        ).order_by(SyncMessage.created_at).limit(limit)

        for msg in msg_query.all():
            d = msg.to_dict(include_deleted=include_deleted, include_blocks=True)
            if d:
                result["messages"].append(d)

    # 拉取渠道商
    if "providers.config" in enabled_scopes:
        prov_query = db.query(Provider).filter(
            Provider.user_id == user_id,
            Provider.updated_at > providers_since
        ).order_by(Provider.updated_at).limit(limit)

        include_keys = "providers.keys" in enabled_scopes
        for prov in prov_query.all():
            d = prov.to_dict(include_deleted=include_deleted, include_keys=include_keys)
            if d:
                result["providers"].append(d)

    return result


# ============ 推送操作 ============

@router.post("/push")
async def push_operations(
    request: PushRequest,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """批量推送操作（幂等）"""
    results = []
    ts = now_ms()

    for op in request.operations:
        # 幂等检查
        existing = db.query(SyncOperation).filter(SyncOperation.op_id == op.op_id).first()
        if existing:
            # 返回之前的结果
            results.append({
                "op_id": op.op_id,
                "status": "duplicate",
                "result": json.loads(existing.result_data) if existing.result_data else None
            })
            continue

        try:
            result = _execute_operation(db, user_id, op, ts)

            # 记录操作
            sync_op = SyncOperation(
                op_id=op.op_id,
                user_id=user_id,
                device_id=op.device_id,
                operation_type=op.op_type,
                operation_data=json.dumps(op.data),
                result_data=json.dumps(result),
                created_at=ts
            )
            db.add(sync_op)

            results.append({
                "op_id": op.op_id,
                "status": "success",
                "result": result
            })
        except Exception as e:
            results.append({
                "op_id": op.op_id,
                "status": "error",
                "error": str(e)
            })

    db.commit()
    return {"results": results, "server_time": ts}


def _execute_operation(db: Session, user_id: int, op: PushOperation, ts: int) -> dict:
    """执行单个操作"""
    data = op.data

    if op.op_type == "upsert_conversation":
        return _upsert_conversation(db, user_id, data, ts)
    elif op.op_type == "append_message":
        return _append_message(db, user_id, data, ts)
    elif op.op_type == "delete":
        return _soft_delete(db, user_id, data, ts)
    elif op.op_type == "restore":
        return _restore(db, user_id, data, ts)
    elif op.op_type == "regen":
        return _regen_replace(db, user_id, data, ts)
    elif op.op_type == "fork":
        return _fork_conversation(db, user_id, data, ts)
    elif op.op_type == "upsert_provider":
        return _upsert_provider(db, user_id, data, ts)
    else:
        raise ValueError(f"未知操作类型: {op.op_type}")


def _upsert_conversation(db: Session, user_id: int, data: dict, ts: int) -> dict:
    """创建或更新会话"""
    conv_id = data.get("id")
    existing = db.query(Conversation).filter(
        Conversation.id == conv_id,
        Conversation.user_id == user_id
    ).first()

    if existing:
        # 更新
        for key in ["title", "display_name", "avatar_url", "character_image",
                    "self_address", "address_user", "voice_file", "persona_prompt",
                    "default_provider", "session_provider", "is_pinned", "is_favorite",
                    "is_muted", "notification_sound", "last_message", "last_message_time",
                    "unread_count"]:
            if key in data:
                setattr(existing, key, data[key])
        existing.updated_at = ts
        return {"id": conv_id, "action": "updated"}
    else:
        # 创建
        conv = Conversation(
            id=conv_id,
            user_id=user_id,
            title=data.get("title", ""),
            display_name=data.get("display_name", ""),
            avatar_url=data.get("avatar_url"),
            character_image=data.get("character_image"),
            self_address=data.get("self_address"),
            address_user=data.get("address_user"),
            voice_file=data.get("voice_file"),
            persona_prompt=data.get("persona_prompt", ""),
            default_provider=data.get("default_provider"),
            session_provider=data.get("session_provider"),
            is_pinned=data.get("is_pinned", False),
            is_favorite=data.get("is_favorite", False),
            is_muted=data.get("is_muted", False),
            notification_sound=data.get("notification_sound", True),
            last_message=data.get("last_message"),
            last_message_time=data.get("last_message_time"),
            unread_count=data.get("unread_count", 0),
            parent_conversation_id=data.get("parent_conversation_id"),
            fork_from_message_id=data.get("fork_from_message_id"),
            created_at=ts,
            updated_at=ts
        )
        db.add(conv)
        return {"id": conv_id, "action": "created"}


def _append_message(db: Session, user_id: int, data: dict, ts: int) -> dict:
    """追加消息"""
    msg_id = data.get("id")
    conv_id = data.get("conversation_id")

    # 检查会话存在
    conv = db.query(Conversation).filter(
        Conversation.id == conv_id,
        Conversation.user_id == user_id
    ).first()
    if not conv:
        raise ValueError(f"会话不存在: {conv_id}")

    # 创建消息
    msg = SyncMessage(
        id=msg_id,
        user_id=user_id,
        conversation_id=conv_id,
        role=data.get("role"),
        content=data.get("content", ""),
        status=data.get("status", "sent"),
        created_at=ts
    )
    db.add(msg)

    # 创建 blocks
    blocks = data.get("blocks", [])
    for i, b in enumerate(blocks):
        block = MessageBlock(
            id=b.get("id"),
            message_id=msg_id,
            type=b.get("type"),
            status=b.get("status", "success"),
            data=json.dumps(b.get("data", {})),
            sort_order=b.get("sort_order", i),
            created_at=ts
        )
        db.add(block)

    # 更新会话摘要
    conv.last_message = data.get("content", "")[:100]
    conv.last_message_time = ts
    conv.updated_at = ts

    return {"id": msg_id, "action": "created"}


def _soft_delete(db: Session, user_id: int, data: dict, ts: int) -> dict:
    """软删除（进入回收站）"""
    target_type = data.get("type")  # 'conversation', 'message', 'provider'
    target_id = data.get("id")
    purge_at = ts + RECYCLE_BIN_MS

    if target_type == "conversation":
        obj = db.query(Conversation).filter(
            Conversation.id == target_id,
            Conversation.user_id == user_id
        ).first()
    elif target_type == "message":
        obj = db.query(SyncMessage).filter(
            SyncMessage.id == target_id,
            SyncMessage.user_id == user_id
        ).first()
    elif target_type == "provider":
        obj = db.query(Provider).filter(
            Provider.id == target_id,
            Provider.user_id == user_id
        ).first()
    else:
        raise ValueError(f"未知删除类型: {target_type}")

    if not obj:
        raise ValueError(f"对象不存在: {target_type}/{target_id}")

    obj.deleted_at = ts
    obj.purge_at = purge_at

    # 如果是会话，同时软删除其消息
    if target_type == "conversation":
        db.query(SyncMessage).filter(
            SyncMessage.conversation_id == target_id
        ).update({"deleted_at": ts, "purge_at": purge_at})

    return {"id": target_id, "type": target_type, "action": "deleted", "purge_at": purge_at}


def _restore(db: Session, user_id: int, data: dict, ts: int) -> dict:
    """从回收站恢复"""
    target_type = data.get("type")
    target_id = data.get("id")

    if target_type == "conversation":
        obj = db.query(Conversation).filter(
            Conversation.id == target_id,
            Conversation.user_id == user_id
        ).first()
    elif target_type == "message":
        obj = db.query(SyncMessage).filter(
            SyncMessage.id == target_id,
            SyncMessage.user_id == user_id
        ).first()
    elif target_type == "provider":
        obj = db.query(Provider).filter(
            Provider.id == target_id,
            Provider.user_id == user_id
        ).first()
    else:
        raise ValueError(f"未知恢复类型: {target_type}")

    if not obj:
        raise ValueError(f"对象不存在: {target_type}/{target_id}")

    obj.deleted_at = None
    obj.purge_at = None

    # 如果是会话，同时恢复其消息
    if target_type == "conversation":
        db.query(SyncMessage).filter(
            SyncMessage.conversation_id == target_id
        ).update({"deleted_at": None, "purge_at": None})

    return {"id": target_id, "type": target_type, "action": "restored"}


def _regen_replace(db: Session, user_id: int, data: dict, ts: int) -> dict:
    """重生成覆盖（原子事务）

    1. 旧消息软删除 + replaced_by 指向新消息
    2. 插入新消息
    3. 更新会话摘要
    """
    old_msg_id = data.get("old_message_id")
    new_msg_data = data.get("new_message")

    # 获取旧消息
    old_msg = db.query(SyncMessage).filter(
        SyncMessage.id == old_msg_id,
        SyncMessage.user_id == user_id
    ).first()
    if not old_msg:
        raise ValueError(f"旧消息不存在: {old_msg_id}")

    # 验证是最后一条 assistant 消息
    if old_msg.role != "assistant":
        raise ValueError("只能对 assistant 消息执行重生成")

    conv_id = old_msg.conversation_id
    new_msg_id = new_msg_data.get("id")

    # 1. 旧消息进回收站
    old_msg.deleted_at = ts
    old_msg.purge_at = ts + RECYCLE_BIN_MS
    old_msg.replaced_by = new_msg_id

    # 2. 创建新消息
    new_msg = SyncMessage(
        id=new_msg_id,
        user_id=user_id,
        conversation_id=conv_id,
        role="assistant",
        content=new_msg_data.get("content", ""),
        status=new_msg_data.get("status", "sent"),
        created_at=ts
    )
    db.add(new_msg)

    # 创建新消息的 blocks
    for i, b in enumerate(new_msg_data.get("blocks", [])):
        block = MessageBlock(
            id=b.get("id"),
            message_id=new_msg_id,
            type=b.get("type"),
            status=b.get("status", "success"),
            data=json.dumps(b.get("data", {})),
            sort_order=b.get("sort_order", i),
            created_at=ts
        )
        db.add(block)

    # 3. 更新会话摘要
    conv = db.query(Conversation).filter(Conversation.id == conv_id).first()
    if conv:
        conv.last_message = new_msg_data.get("content", "")[:100]
        conv.last_message_time = ts
        conv.updated_at = ts

    return {
        "old_message_id": old_msg_id,
        "new_message_id": new_msg_id,
        "action": "replaced"
    }


def _fork_conversation(db: Session, user_id: int, data: dict, ts: int) -> dict:
    """创建分支会话"""
    parent_conv_id = data.get("parent_conversation_id")
    fork_from_msg_id = data.get("fork_from_message_id")
    new_conv_id = data.get("new_conversation_id")

    # 获取父会话
    parent_conv = db.query(Conversation).filter(
        Conversation.id == parent_conv_id,
        Conversation.user_id == user_id
    ).first()
    if not parent_conv:
        raise ValueError(f"父会话不存在: {parent_conv_id}")

    # 创建分支会话
    new_conv = Conversation(
        id=new_conv_id,
        user_id=user_id,
        title=data.get("title", f"{parent_conv.title} (分支)"),
        display_name=parent_conv.display_name,
        avatar_url=parent_conv.avatar_url,
        character_image=parent_conv.character_image,
        self_address=parent_conv.self_address,
        address_user=parent_conv.address_user,
        voice_file=parent_conv.voice_file,
        persona_prompt=parent_conv.persona_prompt,
        default_provider=parent_conv.default_provider,
        session_provider=parent_conv.session_provider,
        is_pinned=False,
        is_favorite=False,
        is_muted=parent_conv.is_muted,
        notification_sound=parent_conv.notification_sound,
        parent_conversation_id=parent_conv_id,
        fork_from_message_id=fork_from_msg_id,
        created_at=ts,
        updated_at=ts
    )
    db.add(new_conv)

    # 复制分叉点之前的消息（可选，根据产品需求）
    if data.get("copy_messages", True):
        # 获取分叉点消息的创建时间
        fork_msg = db.query(SyncMessage).filter(SyncMessage.id == fork_from_msg_id).first()
        if fork_msg:
            # 复制该时间点之前的所有消息
            old_msgs = db.query(SyncMessage).filter(
                SyncMessage.conversation_id == parent_conv_id,
                SyncMessage.created_at <= fork_msg.created_at,
                SyncMessage.deleted_at.is_(None)
            ).all()

            for old_msg in old_msgs:
                new_msg_id = f"{old_msg.id}_fork_{new_conv_id[:8]}"
                new_msg = SyncMessage(
                    id=new_msg_id,
                    user_id=user_id,
                    conversation_id=new_conv_id,
                    role=old_msg.role,
                    content=old_msg.content,
                    status=old_msg.status,
                    created_at=old_msg.created_at
                )
                db.add(new_msg)

                # 复制 blocks
                for old_block in old_msg.blocks:
                    new_block = MessageBlock(
                        id=f"{old_block.id}_fork_{new_conv_id[:8]}",
                        message_id=new_msg_id,
                        type=old_block.type,
                        status=old_block.status,
                        data=old_block.data,
                        sort_order=old_block.sort_order,
                        created_at=old_block.created_at
                    )
                    db.add(new_block)

    return {
        "new_conversation_id": new_conv_id,
        "parent_conversation_id": parent_conv_id,
        "fork_from_message_id": fork_from_msg_id,
        "action": "forked"
    }


def _upsert_provider(db: Session, user_id: int, data: dict, ts: int) -> dict:
    """创建或更新渠道商配置"""
    prov_id = data.get("id")
    existing = db.query(Provider).filter(
        Provider.id == prov_id,
        Provider.user_id == user_id
    ).first()

    if existing:
        # 更新
        for key in ["display_name", "api_base_url", "enabled", "model_type"]:
            if key in data:
                setattr(existing, key, data[key])
        for key in ["capabilities", "custom_config", "visible_models", "hidden_models"]:
            if key in data:
                setattr(existing, key, json.dumps(data[key]))
        if "api_keys" in data:
            # 加密存储
            existing.api_keys_encrypted = encrypt_api_keys(data["api_keys"])
        existing.updated_at = ts
        return {"id": prov_id, "action": "updated"}
    else:
        # 创建
        prov = Provider(
            id=prov_id,
            user_id=user_id,
            display_name=data.get("display_name", ""),
            api_base_url=data.get("api_base_url", ""),
            enabled=data.get("enabled", True),
            capabilities=json.dumps(data.get("capabilities", [])),
            custom_config=json.dumps(data.get("custom_config", {})),
            model_type=data.get("model_type"),
            visible_models=json.dumps(data.get("visible_models", [])),
            hidden_models=json.dumps(data.get("hidden_models", [])),
            api_keys_encrypted=encrypt_api_keys(data.get("api_keys", [])),  # 加密存储
            created_at=ts,
            updated_at=ts
        )
        db.add(prov)
        return {"id": prov_id, "action": "created"}


# ============ 回收站管理 ============

@router.get("/recycle-bin")
async def get_recycle_bin(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取回收站内容"""
    ts = now_ms()

    conversations = db.query(Conversation).filter(
        Conversation.user_id == user_id,
        Conversation.deleted_at.isnot(None),
        Conversation.purge_at > ts
    ).all()

    messages = db.query(SyncMessage).filter(
        SyncMessage.user_id == user_id,
        SyncMessage.deleted_at.isnot(None),
        SyncMessage.purge_at > ts
    ).all()

    providers = db.query(Provider).filter(
        Provider.user_id == user_id,
        Provider.deleted_at.isnot(None),
        Provider.purge_at > ts
    ).all()

    return {
        "conversations": [c.to_dict(include_deleted=True) for c in conversations],
        "messages": [m.to_dict(include_deleted=True) for m in messages],
        "providers": [p.to_dict(include_deleted=True) for p in providers],
        "server_time": ts
    }


# ============ 清理过期数据（定时任务调用） ============

@router.post("/purge-expired")
async def purge_expired(
    admin_key: str,
    db: Session = Depends(get_db)
):
    """清理过期的回收站数据（需要管理员密钥）"""
    # 简单的管理员验证（生产环境应使用更安全的方式）
    import os
    if admin_key != os.getenv("ADMIN_PURGE_KEY", "default_purge_key"):
        raise HTTPException(403, "无权限")

    ts = now_ms()
    purged = {"conversations": 0, "messages": 0, "providers": 0, "blocks": 0}

    # 清理过期会话
    expired_convs = db.query(Conversation).filter(
        Conversation.purge_at.isnot(None),
        Conversation.purge_at <= ts
    ).all()
    for conv in expired_convs:
        db.delete(conv)
        purged["conversations"] += 1

    # 清理过期消息
    expired_msgs = db.query(SyncMessage).filter(
        SyncMessage.purge_at.isnot(None),
        SyncMessage.purge_at <= ts
    ).all()
    for msg in expired_msgs:
        db.delete(msg)
        purged["messages"] += 1

    # 清理过期渠道商
    expired_provs = db.query(Provider).filter(
        Provider.purge_at.isnot(None),
        Provider.purge_at <= ts
    ).all()
    for prov in expired_provs:
        db.delete(prov)
        purged["providers"] += 1

    db.commit()
    return {"purged": purged, "server_time": ts}
