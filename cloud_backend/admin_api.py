"""管理员API"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from sqlalchemy import func
from typing import List, Optional
from datetime import datetime
from pydantic import BaseModel
import secrets
import string

from database import get_db
from auth import get_current_admin_user
from models import (
    User, InviteCode, Contact, Message, UserSettings,
    ApiKeyPool, UserQuota, DataBackup, CloudTrigger, MemoryStore
)

router = APIRouter()


# ============ Pydantic模型 ============

class CreateInviteRequest(BaseModel):
    code: Optional[str] = None
    max_uses: int = 1


class UpdateInviteRequest(BaseModel):
    max_uses: Optional[int] = None
    enabled: Optional[bool] = None


class InviteCodeResponse(BaseModel):
    code: str
    max_uses: int
    used_count: int
    enabled: bool
    created_at: str


class UserStatsResponse(BaseModel):
    id: int
    username: str
    email: Optional[str]
    unique_id: Optional[str]
    user_level: int
    expires_at: Optional[str]
    is_admin: bool
    is_active: bool
    created_at: Optional[str]
    contacts_count: int
    messages_count: int


class UpdateUserLevelRequest(BaseModel):
    """更新用户等级请求"""
    user_level: int
    expires_at: Optional[datetime] = None


# ============ 邀请码管理 ============

def generate_invite_code(length: int = 12) -> str:
    """生成随机邀请码"""
    chars = string.ascii_uppercase + string.digits
    return ''.join(secrets.choice(chars) for _ in range(length))


@router.post("/invites", response_model=InviteCodeResponse)
async def create_invite(
    request: CreateInviteRequest,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """创建邀请码"""
    # 生成或使用指定的邀请码
    code = request.code if request.code else generate_invite_code()
    
    # 检查是否已存在
    existing = db.query(InviteCode).filter(InviteCode.code == code).first()
    if existing:
        raise HTTPException(status_code=400, detail="邀请码已存在")
    
    # 创建新邀请码
    invite = InviteCode(
        code=code,
        max_uses=request.max_uses
    )
    db.add(invite)
    db.commit()
    db.refresh(invite)
    
    return InviteCodeResponse(**invite.to_dict())


@router.get("/invites", response_model=List[InviteCodeResponse])
async def list_invites(
    skip: int = 0,
    limit: int = 100,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """获取邀请码列表"""
    invites = db.query(InviteCode).offset(skip).limit(limit).all()
    return [InviteCodeResponse(**inv.to_dict()) for inv in invites]


@router.patch("/invites/{code}")
async def update_invite(
    code: str,
    request: UpdateInviteRequest,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """更新邀请码"""
    invite = db.query(InviteCode).filter(InviteCode.code == code).first()
    if not invite:
        raise HTTPException(status_code=404, detail="邀请码不存在")
    
    # 更新字段
    if request.max_uses is not None:
        if request.max_uses < invite.used_count:
            raise HTTPException(
                status_code=400,
                detail=f"最大使用次数不能小于已使用次数({invite.used_count})"
            )
        invite.max_uses = request.max_uses
    
    if request.enabled is not None:
        invite.enabled = request.enabled
    
    db.commit()
    db.refresh(invite)
    
    return InviteCodeResponse(**invite.to_dict())


@router.delete("/invites/{code}")
async def delete_invite(
    code: str,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """删除邀请码"""
    invite = db.query(InviteCode).filter(InviteCode.code == code).first()
    if not invite:
        raise HTTPException(status_code=404, detail="邀请码不存在")
    
    db.delete(invite)
    db.commit()
    
    return {"status": "ok", "message": "邀请码已删除"}


# ============ 用户管理 ============

@router.get("/users", response_model=List[UserStatsResponse])
async def list_users(
    skip: int = 0,
    limit: int = 100,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """获取用户列表（包含统计信息）"""
    users = db.query(User).offset(skip).limit(limit).all()
    
    result = []
    for user in users:
        # 统计用户数据
        contacts_count = db.query(Contact).filter(
            Contact.user_id == user.id,
            Contact.is_deleted == False
        ).count()
        
        messages_count = db.query(Message).filter(
            Message.user_id == user.id,
            Message.is_deleted == False
        ).count()
        
        result.append(UserStatsResponse(
            **user.to_dict(),
            contacts_count=contacts_count,
            messages_count=messages_count
        ))
    
    return result


@router.get("/users/{user_id}")
async def get_user_detail(
    user_id: int,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """获取用户详细信息"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    
    # 统计信息
    contacts_count = db.query(Contact).filter(
        Contact.user_id == user_id,
        Contact.is_deleted == False
    ).count()
    
    messages_count = db.query(Message).filter(
        Message.user_id == user_id,
        Message.is_deleted == False
    ).count()
    
    # 最近联系人
    recent_contacts = db.query(Contact).filter(
        Contact.user_id == user_id,
        Contact.is_deleted == False
    ).order_by(Contact.updated_at.desc()).limit(5).all()
    
    return {
        "user": user.to_dict(),
        "stats": {
            "contacts_count": contacts_count,
            "messages_count": messages_count
        },
        "recent_contacts": [c.to_dict() for c in recent_contacts]
    }


@router.patch("/users/{user_id}")
async def update_user(
    user_id: int,
    is_active: Optional[bool] = None,
    is_admin: Optional[bool] = None,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """更新用户状态"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    # 不能修改自己的管理员状态
    if user_id == admin_id and is_admin is not None:
        raise HTTPException(status_code=400, detail="不能修改自己的管理员状态")

    if is_active is not None:
        user.is_active = is_active

    if is_admin is not None:
        user.is_admin = is_admin

    db.commit()
    db.refresh(user)

    return user.to_dict()


@router.post("/users/{unique_id}/level")
async def update_user_level(
    unique_id: str,
    level_data: UpdateUserLevelRequest,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """
    设置用户会员等级和到期时间
    - user_level: 0=免费,1=基础,2=标准,3=高级,4=专业,99=管理员
    - expires_at: 会员到期时间（可选）
    """
    user = db.query(User).filter(User.unique_id == unique_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    # 验证等级范围
    valid_levels = [0, 1, 2, 3, 4, 99]
    if level_data.user_level not in valid_levels:
        raise HTTPException(
            status_code=400,
            detail=f"无效的用户等级，支持: {valid_levels}"
        )

    # 不能修改自己的等级为非管理员
    if user.id == admin_id and level_data.user_level != 99:
        raise HTTPException(status_code=400, detail="不能降低自己的管理员等级")

    user.user_level = level_data.user_level
    if level_data.expires_at:
        user.expires_at = level_data.expires_at

    db.commit()
    db.refresh(user)

    return {
        "status": "ok",
        "user": user.to_dict(),
        "message": f"用户 {unique_id} 等级已更新为 {level_data.user_level}"
    }


@router.delete("/users/{user_id}")
async def delete_user(
    user_id: int,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """删除用户（及其所有数据）"""
    # 不能删除自己
    if user_id == admin_id:
        raise HTTPException(status_code=400, detail="不能删除自己")
    
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    
    # 删除用户的所有数据
    db.query(Contact).filter(Contact.user_id == user_id).delete()
    db.query(Message).filter(Message.user_id == user_id).delete()
    db.query(UserSettings).filter(UserSettings.user_id == user_id).delete()
    
    # 删除用户
    db.delete(user)
    db.commit()
    
    return {"status": "ok", "message": "用户及其数据已删除"}


# ============ 系统统计 ============

@router.get("/stats")
async def system_stats(
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """系统统计信息（包含云服务统计）"""
    # 用户统计
    total_users = db.query(User).count()
    active_users = db.query(User).filter(User.is_active == True).count()
    admin_users = db.query(User).filter(User.user_level == 99).count()

    # 会员分级统计
    level_stats = {}
    for level in [0, 1, 2, 3, 4, 99]:
        count = db.query(User).filter(User.user_level == level).count()
        level_names = {0: "免费", 1: "基础", 2: "标准", 3: "高级", 4: "专业", 99: "管理员"}
        level_stats[f"level_{level}_{level_names[level]}"] = count

    # 数据统计
    total_contacts = db.query(Contact).filter(Contact.is_deleted == False).count()
    total_messages = db.query(Message).filter(Message.is_deleted == False).count()

    # 邀请码统计
    total_invites = db.query(InviteCode).count()
    active_invites = db.query(InviteCode).filter(
        InviteCode.enabled == True,
        InviteCode.used_count < InviteCode.max_uses
    ).count()

    # 云服务统计
    total_api_keys = db.query(ApiKeyPool).count()
    active_api_keys = db.query(ApiKeyPool).filter(ApiKeyPool.is_active == True).count()

    total_backups = db.query(DataBackup).count()
    users_with_backups = db.query(func.count(func.distinct(DataBackup.user_id))).scalar() or 0

    total_triggers = db.query(CloudTrigger).count()
    active_triggers = db.query(CloudTrigger).filter(CloudTrigger.is_active == True).count()

    total_memories = db.query(MemoryStore).count()
    users_with_memories = db.query(func.count(func.distinct(MemoryStore.user_id))).scalar() or 0

    return {
        "users": {
            "total": total_users,
            "active": active_users,
            "admin": admin_users,
            "by_level": level_stats
        },
        "data": {
            "contacts": total_contacts,
            "messages": total_messages
        },
        "invites": {
            "total": total_invites,
            "active": active_invites
        },
        "cloud_services": {
            "api_keys": {
                "total": total_api_keys,
                "active": active_api_keys
            },
            "backups": {
                "total": total_backups,
                "users": users_with_backups
            },
            "triggers": {
                "total": total_triggers,
                "active": active_triggers
            },
            "memories": {
                "total": total_memories,
                "users": users_with_memories
            }
        }
    }
