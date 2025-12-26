"""数据库模型定义"""
from sqlalchemy import Column, Integer, BigInteger, String, Boolean, Text, DateTime, ForeignKey, Index, UniqueConstraint
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from database import Base
import json
from typing import Optional, List


class User(Base):
    """用户表"""
    __tablename__ = "users"
    
    id = Column(Integer, primary_key=True, index=True)
    username = Column(String(100), unique=True, index=True, nullable=False)
    email = Column(String(200), unique=True, index=True, nullable=True)
    password_hash = Column(String(255), nullable=False)
    
    # 会员分级字段
    user_level = Column(Integer, default=0)  # 0=免费,1=基础,2=标准,3=高级,4=专业,99=管理员
    unique_id = Column(String(50), unique=True, nullable=True, index=True)  # 唯一ID如USER-00001
    expires_at = Column(DateTime(timezone=True), nullable=True)  # 会员到期时间
    
    is_admin = Column(Boolean, default=False)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    def to_dict(self):
        return {
            "id": self.id,
            "username": self.username,
            "email": self.email,
            "user_level": self.user_level,
            "unique_id": self.unique_id,
            "expires_at": self.expires_at.isoformat() if self.expires_at else None,
            "is_admin": self.is_admin,
            "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }


class InviteCode(Base):
    """邀请码表"""
    __tablename__ = "invite_codes"
    
    code = Column(String(50), primary_key=True)
    max_uses = Column(Integer, default=1)
    used_count = Column(Integer, default=0)
    enabled = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    def to_dict(self):
        return {
            "code": self.code,
            "max_uses": self.max_uses,
            "used_count": self.used_count,
            "enabled": self.enabled,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }


class Contact(Base):
    """[DEPRECATED] 旧版联系人/角色表 - 请使用 Conversation 表
    保留仅为兼容性，新代码请勿使用
    """
    __tablename__ = "contacts"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    contact_id = Column(String(100), unique=True, nullable=False, index=True)
    name = Column(String(200), nullable=False)
    avatar_url = Column(Text, nullable=True)
    character_data = Column(Text, nullable=True)  # JSON格式
    is_deleted = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    def to_dict(self):
        character_data = None
        if self.character_data:
            try:
                character_data = json.loads(self.character_data)
            except:
                character_data = {}
        
        return {
            "contact_id": self.contact_id,
            "name": self.name,
            "avatar_url": self.avatar_url,
            "character_data": character_data,
            "is_deleted": self.is_deleted,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None
        }


class Message(Base):
    """[DEPRECATED] 旧版消息表 - 请使用 SyncMessage 表
    保留仅为兼容性，新代码请勿使用
    """
    __tablename__ = "messages"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    message_id = Column(String(100), unique=True, nullable=False, index=True)
    contact_id = Column(String(100), nullable=False, index=True)
    role = Column(String(20), nullable=False)  # 'user' or 'assistant'
    content = Column(Text, nullable=False)
    msg_metadata = Column(Text, nullable=True)  # JSON格式
    is_deleted = Column(Boolean, default=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    def to_dict(self):
        metadata = None
        if self.msg_metadata:
            try:
                metadata = json.loads(self.msg_metadata)
            except:
                metadata = {}
        
        return {
            "message_id": self.message_id,
            "contact_id": self.contact_id,
            "role": self.role,
            "content": self.content,
            "metadata": metadata,
            "is_deleted": self.is_deleted,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }


class UserSettings(Base):
    """用户设置表"""
    __tablename__ = "user_settings"
    
    user_id = Column(Integer, ForeignKey("users.id"), primary_key=True)
    settings_json = Column(Text, nullable=False, default="{}")
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    def to_dict(self):
        settings = {}
        if self.settings_json:
            try:
                settings = json.loads(self.settings_json)
            except:
                settings = {}
        
        return {
            "settings": settings,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None
        }


# ============ Key分发和额度管理 ============

class ApiKeyPool(Base):
    """API Key池（管理员配置）"""
    __tablename__ = "api_key_pool"
    
    id = Column(Integer, primary_key=True, index=True)
    provider = Column(String(50), nullable=False)  # 'openai', 'gemini', etc.
    api_key_encrypted = Column(Text, nullable=False)  # 加密存储的Key
    quota_total = Column(Integer, default=0)  # 总额度（tokens）
    quota_used = Column(Integer, default=0)  # 已使用额度
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    notes = Column(Text, nullable=True)  # 备注信息
    
    def to_dict(self):
        return {
            "id": self.id,
            "provider": self.provider,
            "api_key_masked": self.api_key_encrypted[:10] + "..." if self.api_key_encrypted else None,
            "quota_total": self.quota_total,
            "quota_used": self.quota_used,
            "quota_remaining": self.quota_total - self.quota_used,
            "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "notes": self.notes
        }


class UserQuota(Base):
    """用户额度分配"""
    __tablename__ = "user_quota"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    provider = Column(String(50), nullable=False)  # 'openai', 'gemini'
    quota_total = Column(Integer, default=0)  # 分配的总额度
    quota_used = Column(Integer, default=0)  # 已使用额度
    quota_reset_at = Column(DateTime(timezone=True), nullable=True)  # 额度重置时间
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())
    
    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "provider": self.provider,
            "quota_total": self.quota_total,
            "quota_used": self.quota_used,
            "quota_remaining": self.quota_total - self.quota_used,
            "quota_reset_at": self.quota_reset_at.isoformat() if self.quota_reset_at else None,
            "is_active": self.is_active,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None
        }


class QuotaUsageLog(Base):
    """额度使用记录"""
    __tablename__ = "quota_usage_log"
    
    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    provider = Column(String(50), nullable=False)
    tokens_used = Column(Integer, nullable=False)
    request_id = Column(String(100), nullable=True)  # 请求ID（追踪用）
    model_used = Column(String(100), nullable=True)  # 使用的模型
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "provider": self.provider,
            "tokens_used": self.tokens_used,
            "request_id": self.request_id,
            "model_used": self.model_used,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }


# ============ 数据备份 ============

class DataBackup(Base):
    """数据备份"""
    __tablename__ = "data_backups"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    backup_name = Column(String(100), nullable=False)  # 备份名称
    description = Column(String(500), nullable=True)  # 备份描述
    backup_type = Column(String(50), default="manual")  # 'manual', 'auto'
    backup_data = Column(Text, nullable=False)  # JSON格式的完整数据
    file_size = Column(Integer, default=0)  # 备份大小（字节）
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "backup_name": self.backup_name,
            "description": self.description,
            "backup_type": self.backup_type,
            "file_size": self.file_size,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }


# ============ 云触发器 ============

class CloudTrigger(Base):
    """云触发器配置"""
    __tablename__ = "cloud_triggers"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    trigger_name = Column(String(100), nullable=False)  # 触发器名称
    trigger_type = Column(String(50), nullable=False)  # 'schedule', 'event', 'condition'

    # 触发条件配置（JSON）
    # schedule: {"cron": "0 9 * * *", "timezone": "Asia/Shanghai"}
    # event: {"event_type": "new_message", "contact_id": "xxx"}
    # condition: {"condition_type": "quota_low", "threshold": 100}
    trigger_config = Column(Text, nullable=False)

    # 触发后的动作配置（JSON）
    # {"action_type": "backup", "params": {...}}
    # {"action_type": "notification", "params": {"message": "..."}}
    action_config = Column(Text, nullable=False)

    is_active = Column(Boolean, default=True)
    last_triggered_at = Column(DateTime(timezone=True), nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    def to_dict(self):
        trigger_config = {}
        action_config = {}
        try:
            trigger_config = json.loads(self.trigger_config) if self.trigger_config else {}
            action_config = json.loads(self.action_config) if self.action_config else {}
        except:
            pass

        return {
            "id": self.id,
            "user_id": self.user_id,
            "trigger_name": self.trigger_name,
            "trigger_type": self.trigger_type,
            "trigger_config": trigger_config,
            "action_config": action_config,
            "is_active": self.is_active,
            "last_triggered_at": self.last_triggered_at.isoformat() if self.last_triggered_at else None,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None
        }


class TriggerExecutionLog(Base):
    """触发器执行日志"""
    __tablename__ = "trigger_execution_logs"

    id = Column(Integer, primary_key=True, index=True)
    trigger_id = Column(Integer, ForeignKey("cloud_triggers.id"), nullable=False, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)

    status = Column(String(20), nullable=False)  # 'success', 'failed', 'skipped'
    execution_time_ms = Column(Integer, default=0)  # 执行耗时（毫秒）
    result_message = Column(Text, nullable=True)  # 执行结果信息
    error_message = Column(Text, nullable=True)  # 错误信息（如果失败）

    executed_at = Column(DateTime(timezone=True), server_default=func.now())

    def to_dict(self):
        return {
            "id": self.id,
            "trigger_id": self.trigger_id,
            "user_id": self.user_id,
            "status": self.status,
            "execution_time_ms": self.execution_time_ms,
            "result_message": self.result_message,
            "error_message": self.error_message,
            "executed_at": self.executed_at.isoformat() if self.executed_at else None
        }


# ============ 云记忆库 ============

class MemoryStore(Base):
    """云记忆存储"""
    __tablename__ = "memory_store"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    contact_id = Column(String(100), nullable=True, index=True)  # 关联的联系人ID（可选）

    memory_type = Column(String(50), nullable=False)  # 'conversation', 'fact', 'preference', 'custom'
    memory_key = Column(String(200), nullable=False, index=True)  # 记忆标识
    memory_content = Column(Text, nullable=False)  # 记忆内容

    # 向量嵌入（JSON存储，用于语义检索）
    # 格式: [0.1, 0.2, ..., 0.768] (OpenAI ada-002: 1536维)
    embedding_vector = Column(Text, nullable=True)

    # 元数据（JSON）
    mem_metadata = Column(Text, nullable=True)  # {"importance": 5, "tags": ["personal"], ...}

    importance_score = Column(Integer, default=5)  # 1-10，重要性评分
    access_count = Column(Integer, default=0)  # 访问次数
    last_accessed_at = Column(DateTime(timezone=True), nullable=True)

    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now())

    def to_dict(self, include_embedding: bool = False):
        metadata = {}
        try:
            metadata = json.loads(self.mem_metadata) if self.mem_metadata else {}
        except:
            pass

        result = {
            "id": self.id,
            "user_id": self.user_id,
            "contact_id": self.contact_id,
            "memory_type": self.memory_type,
            "memory_key": self.memory_key,
            "memory_content": self.memory_content,
            "metadata": metadata,
            "importance_score": self.importance_score,
            "access_count": self.access_count,
            "last_accessed_at": self.last_accessed_at.isoformat() if self.last_accessed_at else None,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "updated_at": self.updated_at.isoformat() if self.updated_at else None
        }

        # 仅在需要时包含向量数据（通常用于内部计算）
        if include_embedding and self.embedding_vector:
            try:
                result["embedding_vector"] = json.loads(self.embedding_vector)
            except:
                pass

        return result


class MemorySearchHistory(Base):
    """记忆搜索历史"""
    __tablename__ = "memory_search_history"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    search_query = Column(Text, nullable=False)  # 搜索查询
    search_type = Column(String(50), nullable=False)  # 'keyword', 'semantic'
    results_count = Column(Integer, default=0)  # 返回结果数
    search_time_ms = Column(Integer, default=0)  # 搜索耗时
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    def to_dict(self):
        return {
            "id": self.id,
            "user_id": self.user_id,
            "search_query": self.search_query,
            "search_type": self.search_type,
            "results_count": self.results_count,
            "search_time_ms": self.search_time_ms,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }


# ============ 云同步核心表（施工手册定义） ============

class SyncScope(Base):
    """用户同步范围配置（全局一份，所有设备共享）

    可勾选的 scope 常量：
    - chat.history: 聊天记录（conversations/messages/message_blocks）
    - characters.cards: 角色卡/联系人资料
    - characters.per_settings: 单角色设置（置顶/收藏/免打扰等）
    - providers.config: 渠道商配置（不含 key）
    - providers.keys: 渠道商 key（加密同步）
    - user.text_inputs: 用户手填文本类设置
    """
    __tablename__ = "sync_scopes"

    user_id = Column(Integer, ForeignKey("users.id"), primary_key=True)
    # JSON 数组，如 ["chat.history", "characters.cards", "providers.keys"]
    enabled_scopes = Column(Text, nullable=False, default='["chat.history", "characters.cards"]')
    updated_at = Column(BigInteger, nullable=False)  # unix ms

    def to_dict(self):
        scopes = []
        try:
            scopes = json.loads(self.enabled_scopes) if self.enabled_scopes else []
        except:
            scopes = []
        return {
            "user_id": self.user_id,
            "enabled_scopes": scopes,
            "updated_at": self.updated_at
        }


class Conversation(Base):
    """会话/联系人/角色卡表（施工手册 4.1）

    用途：对话列表页秒开 + 角色卡信息 + 单角色设置
    """
    __tablename__ = "conversations"

    id = Column(String(100), primary_key=True)  # UUID
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)

    # 基础信息
    title = Column(String(200), nullable=False)
    display_name = Column(String(200), nullable=False)
    avatar_url = Column(Text, nullable=True)
    character_image = Column(Text, nullable=True)  # 本地相对路径或云端资源 key

    # 角色卡字段（scope: characters.cards）
    self_address = Column(String(100), nullable=True)  # 角色自称
    address_user = Column(String(100), nullable=True)  # 角色对用户的称呼
    voice_file = Column(Text, nullable=True)  # 语音文件
    persona_prompt = Column(Text, nullable=False, default='')  # 人设 prompt

    # 单角色设置（scope: characters.per_settings）
    default_provider = Column(String(100), nullable=True)
    session_provider = Column(String(100), nullable=True)
    is_pinned = Column(Boolean, nullable=False, default=False)
    is_favorite = Column(Boolean, nullable=False, default=False)
    is_muted = Column(Boolean, nullable=False, default=False)
    notification_sound = Column(Boolean, nullable=False, default=True)

    # 会话摘要缓存（列表页快速显示）
    last_message = Column(Text, nullable=True)
    last_message_time = Column(BigInteger, nullable=True)  # unix ms
    unread_count = Column(Integer, nullable=False, default=0)

    # 分支字段
    parent_conversation_id = Column(String(100), nullable=True, index=True)  # 分支来源
    fork_from_message_id = Column(String(100), nullable=True)  # 分支起点消息 id

    # 冲突字段
    conflict_of = Column(String(100), nullable=True)  # 冲突副本来源 id

    # 回收站字段
    deleted_at = Column(BigInteger, nullable=True, index=True)  # unix ms
    purge_at = Column(BigInteger, nullable=True)  # 回收站到期时间，unix ms

    # 时间戳
    created_at = Column(BigInteger, nullable=False)  # unix ms
    updated_at = Column(BigInteger, nullable=False, index=True)  # unix ms

    # 关系
    messages = relationship("SyncMessage", back_populates="conversation", cascade="all, delete-orphan")

    __table_args__ = (
        Index('idx_conv_user_updated', 'user_id', 'updated_at'),
        Index('idx_conv_user_pinned', 'user_id', 'is_pinned', 'updated_at'),
    )

    def to_dict(self, include_deleted: bool = False):
        if not include_deleted and self.deleted_at:
            return None
        return {
            "id": self.id,
            "title": self.title,
            "display_name": self.display_name,
            "avatar_url": self.avatar_url,
            "character_image": self.character_image,
            "self_address": self.self_address,
            "address_user": self.address_user,
            "voice_file": self.voice_file,
            "persona_prompt": self.persona_prompt,
            "default_provider": self.default_provider,
            "session_provider": self.session_provider,
            "is_pinned": self.is_pinned,
            "is_favorite": self.is_favorite,
            "is_muted": self.is_muted,
            "notification_sound": self.notification_sound,
            "last_message": self.last_message,
            "last_message_time": self.last_message_time,
            "unread_count": self.unread_count,
            "parent_conversation_id": self.parent_conversation_id,
            "fork_from_message_id": self.fork_from_message_id,
            "conflict_of": self.conflict_of,
            "deleted_at": self.deleted_at,
            "purge_at": self.purge_at,
            "created_at": self.created_at,
            "updated_at": self.updated_at
        }


class SyncMessage(Base):
    """消息表（施工手册 4.2）

    用途：聊天页分页加载；消息内容不可编辑
    """
    __tablename__ = "sync_messages"

    id = Column(String(100), primary_key=True)  # UUID
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    conversation_id = Column(String(100), ForeignKey("conversations.id", ondelete="CASCADE"), nullable=False)

    role = Column(String(20), nullable=False)  # 'user' | 'assistant'
    content = Column(Text, nullable=False)  # fallback 预览文本
    status = Column(String(20), nullable=False, default='sent')  # 'sending' | 'sent' | 'failed'

    # 重生成覆盖字段
    replaced_by = Column(String(100), nullable=True, index=True)  # 旧消息指向新消息

    # 冲突字段
    conflict_of = Column(String(100), nullable=True)

    # 回收站字段
    deleted_at = Column(BigInteger, nullable=True, index=True)
    purge_at = Column(BigInteger, nullable=True)

    # 时间戳
    created_at = Column(BigInteger, nullable=False)  # unix ms

    # 关系
    conversation = relationship("Conversation", back_populates="messages")
    blocks = relationship("MessageBlock", back_populates="message", cascade="all, delete-orphan")

    __table_args__ = (
        Index('idx_msg_conv_created', 'conversation_id', 'created_at'),
        Index('idx_msg_user_created', 'user_id', 'created_at'),
    )

    def to_dict(self, include_deleted: bool = False, include_blocks: bool = False):
        if not include_deleted and self.deleted_at:
            return None
        result = {
            "id": self.id,
            "conversation_id": self.conversation_id,
            "role": self.role,
            "content": self.content,
            "status": self.status,
            "replaced_by": self.replaced_by,
            "conflict_of": self.conflict_of,
            "deleted_at": self.deleted_at,
            "purge_at": self.purge_at,
            "created_at": self.created_at
        }
        if include_blocks:
            result["blocks"] = [b.to_dict() for b in self.blocks if not b.deleted_at or include_deleted]
        return result


class MessageBlock(Base):
    """多模态内容块（施工手册 4.3）

    用途：一条消息的结构化内容（文本/图片/音频/表情等）
    """
    __tablename__ = "message_blocks"

    id = Column(String(100), primary_key=True)  # UUID
    message_id = Column(String(100), ForeignKey("sync_messages.id", ondelete="CASCADE"), nullable=False)

    type = Column(String(50), nullable=False)  # 'mainText' | 'image' | 'audio' | 'emoji' | 'tool' | 'thinking'
    status = Column(String(20), nullable=False, default='success')  # 'pending' | 'success' | 'error'
    data = Column(Text, nullable=False)  # JSON，格式见施工手册 4.6
    sort_order = Column(Integer, nullable=False, default=0)

    # 回收站（跟随消息）
    deleted_at = Column(BigInteger, nullable=True)

    created_at = Column(BigInteger, nullable=False)

    # 关系
    message = relationship("SyncMessage", back_populates="blocks")

    __table_args__ = (
        UniqueConstraint('message_id', 'sort_order', name='uq_block_msg_order'),
        Index('idx_block_msg', 'message_id', 'sort_order'),
    )

    def to_dict(self):
        data = {}
        try:
            data = json.loads(self.data) if self.data else {}
        except:
            data = {}
        return {
            "id": self.id,
            "message_id": self.message_id,
            "type": self.type,
            "status": self.status,
            "data": data,
            "sort_order": self.sort_order,
            "created_at": self.created_at
        }


class Provider(Base):
    """渠道商配置表（施工手册 4.4）

    用途：用户手动输入的渠道商信息，多端同步
    api_keys 字段在云端存储时必须加密（信封加密）
    """
    __tablename__ = "providers"

    id = Column(String(100), primary_key=True)  # providerId
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)

    display_name = Column(String(200), nullable=False)
    api_base_url = Column(Text, nullable=False)
    enabled = Column(Boolean, nullable=False, default=True)

    # JSON 数组
    capabilities = Column(Text, nullable=False, default='[]')
    custom_config = Column(Text, nullable=False, default='{}')
    model_type = Column(String(50), nullable=True)
    visible_models = Column(Text, nullable=False, default='[]')
    hidden_models = Column(Text, nullable=False, default='[]')

    # API Keys（加密存储）
    # 格式：信封加密 JSON，见施工手册 7.1
    api_keys_encrypted = Column(Text, nullable=False, default='[]')

    # 冲突字段
    conflict_of = Column(String(100), nullable=True)

    # 回收站字段
    deleted_at = Column(BigInteger, nullable=True, index=True)
    purge_at = Column(BigInteger, nullable=True)

    # 时间戳
    created_at = Column(BigInteger, nullable=False)
    updated_at = Column(BigInteger, nullable=False, index=True)

    __table_args__ = (
        Index('idx_provider_user_updated', 'user_id', 'updated_at'),
    )

    def to_dict(self, include_deleted: bool = False, include_keys: bool = False):
        if not include_deleted and self.deleted_at:
            return None

        capabilities = []
        custom_config = {}
        visible_models = []
        hidden_models = []
        try:
            capabilities = json.loads(self.capabilities) if self.capabilities else []
            custom_config = json.loads(self.custom_config) if self.custom_config else {}
            visible_models = json.loads(self.visible_models) if self.visible_models else []
            hidden_models = json.loads(self.hidden_models) if self.hidden_models else []
        except:
            pass

        result = {
            "id": self.id,
            "display_name": self.display_name,
            "api_base_url": self.api_base_url,
            "enabled": self.enabled,
            "capabilities": capabilities,
            "custom_config": custom_config,
            "model_type": self.model_type,
            "visible_models": visible_models,
            "hidden_models": hidden_models,
            "conflict_of": self.conflict_of,
            "deleted_at": self.deleted_at,
            "purge_at": self.purge_at,
            "created_at": self.created_at,
            "updated_at": self.updated_at
        }

        # 只有明确请求时才返回 keys（解密后）
        if include_keys:
            from encryption import decrypt_api_keys
            result["api_keys"] = decrypt_api_keys(self.api_keys_encrypted)

        return result


class SyncOperation(Base):
    """同步操作记录（用于幂等性）

    每次客户端写操作都带一个 op_id，服务端记录已处理的 op_id
    对同一 op_id 的重复请求返回相同结果
    """
    __tablename__ = "sync_operations"

    op_id = Column(String(100), primary_key=True)  # UUID
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    device_id = Column(String(100), nullable=False)

    operation_type = Column(String(50), nullable=False)  # 'append_message', 'delete', 'restore', 'regen', 'fork', etc.
    operation_data = Column(Text, nullable=True)  # JSON，操作的输入参数
    result_data = Column(Text, nullable=True)  # JSON，操作的返回结果

    created_at = Column(BigInteger, nullable=False)

    __table_args__ = (
        Index('idx_op_user_created', 'user_id', 'created_at'),
    )

    def to_dict(self):
        return {
            "op_id": self.op_id,
            "device_id": self.device_id,
            "operation_type": self.operation_type,
            "created_at": self.created_at
        }


class SyncCursor(Base):
    """同步游标（每用户每设备）

    记录每个设备的同步位置，用于增量拉取
    """
    __tablename__ = "sync_cursors"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    device_id = Column(String(100), nullable=False)

    # 各资源类型的游标（unix ms）
    conversations_cursor = Column(BigInteger, nullable=False, default=0)
    messages_cursor = Column(BigInteger, nullable=False, default=0)
    providers_cursor = Column(BigInteger, nullable=False, default=0)

    updated_at = Column(BigInteger, nullable=False)

    __table_args__ = (
        UniqueConstraint('user_id', 'device_id', name='uq_cursor_user_device'),
        Index('idx_cursor_user', 'user_id'),
    )
