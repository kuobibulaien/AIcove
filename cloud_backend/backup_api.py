"""
数据备份API
提供用户数据的云端备份和恢复功能
"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import func, desc
from typing import List, Optional
from datetime import datetime, timezone
from pydantic import BaseModel, Field

from database import get_db
from auth import get_current_user
from models import User, DataBackup

router = APIRouter()


# ============ Pydantic Models ============

class BackupCreate(BaseModel):
    """创建备份请求"""
    backup_name: str = Field(..., min_length=1, max_length=100, description="备份名称")
    backup_data: str = Field(..., description="备份数据（JSON字符串）")
    description: Optional[str] = Field(None, max_length=500, description="备份描述")


class BackupInfo(BaseModel):
    """备份信息响应"""
    id: int
    backup_name: str
    description: Optional[str]
    file_size: int
    created_at: datetime

    class Config:
        from_attributes = True


class BackupDetail(BaseModel):
    """备份详细信息（包含数据）"""
    id: int
    backup_name: str
    description: Optional[str]
    backup_data: str
    file_size: int
    created_at: datetime

    class Config:
        from_attributes = True


class BackupStats(BaseModel):
    """备份统计信息"""
    total_backups: int
    total_size: int
    oldest_backup: Optional[datetime]
    newest_backup: Optional[datetime]


# ============ Helper Functions ============

def check_user_level(user: User, required_level: int):
    """检查用户等级是否满足要求"""
    if user.user_level < required_level:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"此功能需要等级 {required_level} 或更高，您当前等级: {user.user_level}"
        )


def check_membership_expiry(user: User):
    """检查会员是否过期"""
    if user.expires_at and datetime.now(timezone.utc) > user.expires_at:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="会员已过期，请续费后使用"
        )


def calculate_backup_size(data: str) -> int:
    """计算备份数据大小（字节）"""
    return len(data.encode('utf-8'))


# ============ User Endpoints ============

@router.post("/create", response_model=BackupInfo, status_code=status.HTTP_201_CREATED)
async def create_backup(
    backup_data: BackupCreate,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    创建新备份
    - 需要 Level 1+ 权限
    - 自动计算备份大小
    """
    # 获取用户信息
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    # 检查权限和会员状态
    check_user_level(user, 1)
    check_membership_expiry(user)

    # 计算备份大小
    file_size = calculate_backup_size(backup_data.backup_data)

    # 创建备份记录
    new_backup = DataBackup(
        user_id=user_id,
        backup_name=backup_data.backup_name,
        description=backup_data.description,
        backup_data=backup_data.backup_data,
        file_size=file_size
    )

    db.add(new_backup)
    db.commit()
    db.refresh(new_backup)

    return new_backup


@router.get("/list", response_model=List[BackupInfo])
async def list_backups(
    skip: int = 0,
    limit: int = 50,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    获取用户的备份列表
    - 仅返回备份信息，不包含备份数据内容
    - 按创建时间倒序排列
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 1)

    backups = db.query(DataBackup).filter(
        DataBackup.user_id == user_id
    ).order_by(
        desc(DataBackup.created_at)
    ).offset(skip).limit(limit).all()

    return backups


@router.get("/{backup_id}", response_model=BackupDetail)
async def get_backup(
    backup_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    获取备份详情（包含备份数据）
    - 用于恢复备份
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 1)

    backup = db.query(DataBackup).filter(
        DataBackup.id == backup_id,
        DataBackup.user_id == user_id
    ).first()

    if not backup:
        raise HTTPException(status_code=404, detail="备份不存在")

    return backup


@router.post("/{backup_id}/restore")
async def restore_backup(
    backup_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    恢复备份
    - 实际上只是获取备份数据，由客户端完成恢复操作
    - 返回备份数据供客户端使用
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 1)
    check_membership_expiry(user)

    backup = db.query(DataBackup).filter(
        DataBackup.id == backup_id,
        DataBackup.user_id == user_id
    ).first()

    if not backup:
        raise HTTPException(status_code=404, detail="备份不存在")

    return {
        "id": backup.id,
        "backup_name": backup.backup_name,
        "backup_data": backup.backup_data,
        "created_at": backup.created_at
    }


@router.delete("/{backup_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_backup(
    backup_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    删除备份
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 1)

    backup = db.query(DataBackup).filter(
        DataBackup.id == backup_id,
        DataBackup.user_id == user_id
    ).first()

    if not backup:
        raise HTTPException(status_code=404, detail="备份不存在")

    db.delete(backup)
    db.commit()

    return None


@router.get("/stats/my", response_model=BackupStats)
async def get_my_backup_stats(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    获取当前用户的备份统计信息
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 1)

    stats = db.query(
        func.count(DataBackup.id).label('total_backups'),
        func.sum(DataBackup.file_size).label('total_size'),
        func.min(DataBackup.created_at).label('oldest_backup'),
        func.max(DataBackup.created_at).label('newest_backup')
    ).filter(DataBackup.user_id == user_id).first()

    return BackupStats(
        total_backups=stats.total_backups or 0,
        total_size=stats.total_size or 0,
        oldest_backup=stats.oldest_backup,
        newest_backup=stats.newest_backup
    )


# ============ Admin Endpoints ============

@router.get("/admin/overview", response_model=dict)
async def get_backup_overview(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    管理员：获取所有备份的概览统计
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user or user.user_level != 99:
        raise HTTPException(status_code=403, detail="需要管理员权限")

    # 总体统计
    total_stats = db.query(
        func.count(DataBackup.id).label('total_backups'),
        func.sum(DataBackup.file_size).label('total_size'),
        func.count(func.distinct(DataBackup.user_id)).label('users_with_backups')
    ).first()

    # 每个用户的备份数量（Top 10）
    top_users = db.query(
        User.unique_id,
        User.username,
        func.count(DataBackup.id).label('backup_count'),
        func.sum(DataBackup.file_size).label('total_size')
    ).join(
        DataBackup, User.id == DataBackup.user_id
    ).group_by(
        User.id
    ).order_by(
        desc('backup_count')
    ).limit(10).all()

    return {
        "total_backups": total_stats.total_backups or 0,
        "total_size_bytes": total_stats.total_size or 0,
        "users_with_backups": total_stats.users_with_backups or 0,
        "top_users": [
            {
                "unique_id": u.unique_id,
                "username": u.username,
                "backup_count": u.backup_count,
                "total_size": u.total_size
            }
            for u in top_users
        ]
    }


@router.get("/admin/user/{unique_id}", response_model=List[BackupInfo])
async def get_user_backups_by_admin(
    unique_id: str,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    管理员：查看指定用户的所有备份
    """
    admin = db.query(User).filter(User.id == user_id).first()
    if not admin or admin.user_level != 99:
        raise HTTPException(status_code=403, detail="需要管理员权限")

    target_user = db.query(User).filter(User.unique_id == unique_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="用户不存在")

    backups = db.query(DataBackup).filter(
        DataBackup.user_id == target_user.id
    ).order_by(
        desc(DataBackup.created_at)
    ).all()

    return backups


@router.delete("/admin/backup/{backup_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_backup_by_admin(
    backup_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    管理员：删除任意用户的备份
    """
    admin = db.query(User).filter(User.id == user_id).first()
    if not admin or admin.user_level != 99:
        raise HTTPException(status_code=403, detail="需要管理员权限")

    backup = db.query(DataBackup).filter(DataBackup.id == backup_id).first()
    if not backup:
        raise HTTPException(status_code=404, detail="备份不存在")

    db.delete(backup)
    db.commit()

    return None
