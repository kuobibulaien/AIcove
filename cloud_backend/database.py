"""数据库连接和会话管理"""
from sqlalchemy import create_engine
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
import os

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./data/sync.db")

# 创建数据库引擎
engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False} if "sqlite" in DATABASE_URL else {}
)

# 创建会话工厂
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# 声明式基类
Base = declarative_base()


def init_db():
    """初始化数据库表结构"""
    # 确保数据目录存在
    if "sqlite" in DATABASE_URL:
        os.makedirs("data", exist_ok=True)

    # 导入所有模型以确保表被创建
    from models import (
        # 基础表
        User, InviteCode,
        # 旧版表（deprecated，保留兼容）
        Contact, Message,
        # 用户设置
        UserSettings,
        # Key 分发和额度管理
        ApiKeyPool, UserQuota, QuotaUsageLog,
        # 数据备份
        DataBackup,
        # 云触发器
        CloudTrigger, TriggerExecutionLog,
        # 云记忆库
        MemoryStore, MemorySearchHistory,
        # === 云同步核心表（施工手册定义）===
        SyncScope,       # 同步范围配置
        Conversation,    # 会话/角色卡
        SyncMessage,     # 消息
        MessageBlock,    # 多模态内容块
        Provider,        # 渠道商配置
        SyncOperation,   # 幂等操作记录
        SyncCursor,      # 同步游标
    )

    # 创建所有表
    Base.metadata.create_all(bind=engine)


def get_db() -> Session:
    """获取数据库会话（FastAPI依赖注入）"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
