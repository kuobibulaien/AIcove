"""回收站定时清理任务

用法：
1. 直接运行: python purge_task.py
2. 配置 cron/定时任务每天执行一次

环境变量：
- DATABASE_URL: 数据库连接字符串
- ADMIN_PURGE_KEY: 管理员清理密钥（可选，直接运行时不需要）
"""
import os
import sys
import time

# 添加当前目录到路径
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from sqlalchemy.orm import Session
from database import SessionLocal
from models import Conversation, SyncMessage, MessageBlock, Provider


def now_ms() -> int:
    return int(time.time() * 1000)


def purge_expired_data():
    """清理过期的回收站数据"""
    db: Session = SessionLocal()
    ts = now_ms()
    purged = {"conversations": 0, "messages": 0, "blocks": 0, "providers": 0}

    try:
        # 清理过期会话（级联删除消息和 blocks）
        expired_convs = db.query(Conversation).filter(
            Conversation.purge_at.isnot(None),
            Conversation.purge_at <= ts
        ).all()
        for conv in expired_convs:
            db.delete(conv)
            purged["conversations"] += 1

        # 清理过期消息（级联删除 blocks）
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
        print(f"✅ 清理完成: {purged}")
        return purged

    except Exception as e:
        db.rollback()
        print(f"❌ 清理失败: {e}")
        raise
    finally:
        db.close()


if __name__ == "__main__":
    print(f"🗑️ 开始清理过期回收站数据... (当前时间戳: {now_ms()})")
    purge_expired_data()
