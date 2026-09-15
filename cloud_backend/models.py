"""数据库模型定义"""
from sqlalchemy import Column, Integer, String, Boolean, DateTime
from sqlalchemy.sql import func
from database import Base


class User(Base):
    """用户表"""
    __tablename__ = "users"
    
    id = Column(Integer, primary_key=True, index=True)
    username = Column(String(100), unique=True, index=True, nullable=False)
    email = Column(String(200), unique=True, index=True, nullable=True)
    password_hash = Column(String(255), nullable=False)
    
    unique_id = Column(String(50), unique=True, nullable=True, index=True)  # 唯一ID如USER-00001
    
    is_admin = Column(Boolean, default=False)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    
    def to_dict(self):
        return {
            "id": self.id,
            "username": self.username,
            "email": self.email,
            "unique_id": self.unique_id,
            "is_admin": self.is_admin,
            "is_active": self.is_active,
            "created_at": self.created_at.isoformat() if self.created_at else None
        }

