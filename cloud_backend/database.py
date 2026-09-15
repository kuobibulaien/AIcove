"""数据库连接和会话管理"""
import os
import platform

# Python 3.13 在部分 Windows 环境下调用 platform.machine() 会走 WMI 查询，
# 可能在导入 SQLAlchemy 的兼容层时卡死，导致 uvicorn 还没绑定端口就挂起。
# 这里在 SQLAlchemy import 之前提供一个本地稳定值，避免管理面板启动被 WMI 阻塞。
if os.name == "nt":
    _processor_arch = os.getenv("PROCESSOR_ARCHITECTURE") or "AMD64"
    platform.machine = lambda: _processor_arch  # type: ignore[assignment]

from sqlalchemy import create_engine, event
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session

DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./data/sync.db")

# 创建数据库引擎
engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False} if "sqlite" in DATABASE_URL else {}
)

# Keep account IDs from being reused while sync data still references them.
if engine.dialect.name == "sqlite":
    @event.listens_for(engine, "connect")
    def _sqlite_foreign_keys(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA busy_timeout=30000")

# 创建会话工厂
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

# 声明式基类
Base = declarative_base()


def init_db():
    """初始化数据库表结构"""
    # 确保数据目录存在
    if "sqlite" in DATABASE_URL:
        os.makedirs("data", exist_ok=True)

    if engine.dialect.name == "sqlite":
        # Set persistent journal mode at startup, before serving concurrent
        # readers and writers. Keep SQLite's full commit durability.
        with engine.connect() as connection:
            connection.exec_driver_sql("PRAGMA journal_mode=WAL")

    # Register only sync accounts and v3 tables. Existing legacy tables are
    # left untouched; retiring code must never delete stored account data.
    from models import User
    from sync_v3 import models as sync_v3_models

    # 创建所有表
    Base.metadata.create_all(bind=engine)


def get_db() -> Session:
    """获取数据库会话（FastAPI依赖注入）"""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
