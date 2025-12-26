"""Key分发和额度管理API"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from sqlalchemy import desc
from typing import List, Optional
from pydantic import BaseModel
from datetime import datetime, timedelta
from cryptography.fernet import Fernet
import os

from database import get_db
from auth import get_current_user, get_current_admin_user
from models import User, ApiKeyPool, UserQuota, QuotaUsageLog

router = APIRouter()

# 加密密钥（从环境变量读取，生产环境必须设置）
ENCRYPTION_KEY = os.getenv("ENCRYPTION_KEY", Fernet.generate_key())
cipher = Fernet(ENCRYPTION_KEY)


# ============ Pydantic模型 ============

class KeyPoolCreate(BaseModel):
    provider: str
    api_key: str
    quota_total: int
    notes: Optional[str] = None


class KeyPoolUpdate(BaseModel):
    quota_total: Optional[int] = None
    is_active: Optional[bool] = None
    notes: Optional[str] = None


class QuotaAssign(BaseModel):
    user_id: int
    provider: str
    quota_total: int
    reset_monthly: bool = True  # 是否每月重置


class KeyRequest(BaseModel):
    provider: str


class UsageReport(BaseModel):
    tokens_used: int
    request_id: Optional[str] = None
    model_used: Optional[str] = None


# ============ 工具函数 ============

def encrypt_key(api_key: str) -> str:
    """加密API Key"""
    return cipher.encrypt(api_key.encode()).decode()


def decrypt_key(encrypted_key: str) -> str:
    """解密API Key"""
    return cipher.decrypt(encrypted_key.encode()).decode()


def check_user_level(user: User, min_level: int):
    """检查用户级别"""
    if user.user_level < min_level:
        raise HTTPException(
            status_code=403,
            detail=f"此功能需要Level {min_level}及以上会员（当前Level {user.user_level}）"
        )


# ============ 用户端API ============

@router.get("/providers")
async def get_available_providers(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取可用的Provider列表"""
    user = db.query(User).filter(User.id == user_id).first()
    check_user_level(user, 2)  # 需要Level 2（标准版）
    
    # 查询用户有额度的provider
    quotas = db.query(UserQuota).filter(
        UserQuota.user_id == user_id,
        UserQuota.is_active == True,
        UserQuota.quota_total > UserQuota.quota_used
    ).all()
    
    providers = []
    for quota in quotas:
        providers.append({
            "provider": quota.provider,
            "quota_remaining": quota.quota_total - quota.quota_used,
            "quota_total": quota.quota_total,
            "reset_at": quota.quota_reset_at.isoformat() if quota.quota_reset_at else None
        })
    
    return {"providers": providers}


@router.post("/request")
async def request_key(
    request: KeyRequest,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """请求API Key"""
    user = db.query(User).filter(User.id == user_id).first()
    check_user_level(user, 2)
    
    # 查询用户额度
    quota = db.query(UserQuota).filter(
        UserQuota.user_id == user_id,
        UserQuota.provider == request.provider,
        UserQuota.is_active == True
    ).first()
    
    if not quota:
        raise HTTPException(
            status_code=404,
            detail=f"未找到{request.provider}的额度分配"
        )
    
    if quota.quota_used >= quota.quota_total:
        raise HTTPException(
            status_code=403,
            detail=f"{request.provider}额度已用完"
        )
    
    # 从Key池中获取可用的Key
    key_pool = db.query(ApiKeyPool).filter(
        ApiKeyPool.provider == request.provider,
        ApiKeyPool.is_active == True,
        ApiKeyPool.quota_used < ApiKeyPool.quota_total
    ).first()
    
    if not key_pool:
        raise HTTPException(
            status_code=503,
            detail=f"{request.provider}暂时不可用，请联系管理员"
        )
    
    # 解密返回Key
    api_key = decrypt_key(key_pool.api_key_encrypted)
    
    return {
        "provider": request.provider,
        "api_key": api_key,
        "quota_remaining": quota.quota_total - quota.quota_used,
        "message": "请妥善保管此Key，不要泄露"
    }


@router.get("/quota")
async def get_user_quota(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """查看用户额度"""
    user = db.query(User).filter(User.id == user_id).first()
    check_user_level(user, 2)
    
    quotas = db.query(UserQuota).filter(
        UserQuota.user_id == user_id
    ).all()
    
    return {
        "quotas": [q.to_dict() for q in quotas],
        "user_level": user.user_level
    }


@router.post("/usage/report")
async def report_usage(
    usage: UsageReport,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """报告Key使用情况（客户端主动报告）"""
    # 注：这是可选的，也可以通过代理服务器自动记录
    # 暂不实现，因为用户可能伪造数据
    pass


# ============ 管理员API ============

@router.post("/admin/pool")
async def add_key_to_pool(
    key_data: KeyPoolCreate,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """添加Key到池中"""
    # 加密Key
    encrypted_key = encrypt_key(key_data.api_key)
    
    key_pool = ApiKeyPool(
        provider=key_data.provider,
        api_key_encrypted=encrypted_key,
        quota_total=key_data.quota_total,
        notes=key_data.notes
    )
    
    db.add(key_pool)
    db.commit()
    db.refresh(key_pool)
    
    return {
        "status": "success",
        "key_pool": key_pool.to_dict()
    }


@router.get("/admin/pool")
async def list_key_pool(
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """Key池列表"""
    keys = db.query(ApiKeyPool).all()
    return {"keys": [k.to_dict() for k in keys]}


@router.put("/admin/pool/{key_id}")
async def update_key_pool(
    key_id: int,
    update_data: KeyPoolUpdate,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """更新Key池"""
    key_pool = db.query(ApiKeyPool).filter(ApiKeyPool.id == key_id).first()
    if not key_pool:
        raise HTTPException(status_code=404, detail="Key不存在")
    
    if update_data.quota_total is not None:
        key_pool.quota_total = update_data.quota_total
    if update_data.is_active is not None:
        key_pool.is_active = update_data.is_active
    if update_data.notes is not None:
        key_pool.notes = update_data.notes
    
    db.commit()
    db.refresh(key_pool)
    
    return {"status": "success", "key_pool": key_pool.to_dict()}


@router.delete("/admin/pool/{key_id}")
async def delete_key_pool(
    key_id: int,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """删除Key"""
    key_pool = db.query(ApiKeyPool).filter(ApiKeyPool.id == key_id).first()
    if not key_pool:
        raise HTTPException(status_code=404, detail="Key不存在")
    
    db.delete(key_pool)
    db.commit()
    
    return {"status": "success", "message": "Key已删除"}


@router.post("/admin/assign")
async def assign_quota(
    quota_data: QuotaAssign,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """给用户分配额度"""
    # 检查用户是否存在
    user = db.query(User).filter(User.id == quota_data.user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    
    # 检查是否已有额度配置
    existing = db.query(UserQuota).filter(
        UserQuota.user_id == quota_data.user_id,
        UserQuota.provider == quota_data.provider
    ).first()
    
    if existing:
        # 更新现有额度
        existing.quota_total = quota_data.quota_total
        existing.is_active = True
        if quota_data.reset_monthly:
            # 下月1日重置
            next_month = datetime.now().replace(day=1) + timedelta(days=32)
            existing.quota_reset_at = next_month.replace(day=1)
        db.commit()
        db.refresh(existing)
        return {"status": "updated", "quota": existing.to_dict()}
    else:
        # 创建新额度
        quota = UserQuota(
            user_id=quota_data.user_id,
            provider=quota_data.provider,
            quota_total=quota_data.quota_total
        )
        
        if quota_data.reset_monthly:
            next_month = datetime.now().replace(day=1) + timedelta(days=32)
            quota.quota_reset_at = next_month.replace(day=1)
        
        db.add(quota)
        db.commit()
        db.refresh(quota)
        
        return {"status": "created", "quota": quota.to_dict()}


@router.get("/admin/usage")
async def get_usage_stats(
    provider: Optional[str] = None,
    user_id: Optional[int] = None,
    limit: int = 100,
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """查看使用统计"""
    query = db.query(QuotaUsageLog)
    
    if provider:
        query = query.filter(QuotaUsageLog.provider == provider)
    if user_id:
        query = query.filter(QuotaUsageLog.user_id == user_id)
    
    logs = query.order_by(desc(QuotaUsageLog.created_at)).limit(limit).all()
    
    # 统计总用量
    total_used = sum(log.tokens_used for log in logs)
    
    return {
        "logs": [log.to_dict() for log in logs],
        "total_tokens_used": total_used,
        "count": len(logs)
    }


@router.get("/admin/overview")
async def get_quota_overview(
    admin_id: int = Depends(get_current_admin_user),
    db: Session = Depends(get_db)
):
    """额度使用概览"""
    # Key池统计
    key_pools = db.query(ApiKeyPool).all()
    key_pool_stats = {}
    for key in key_pools:
        if key.provider not in key_pool_stats:
            key_pool_stats[key.provider] = {
                "total_keys": 0,
                "total_quota": 0,
                "used_quota": 0
            }
        key_pool_stats[key.provider]["total_keys"] += 1
        key_pool_stats[key.provider]["total_quota"] += key.quota_total
        key_pool_stats[key.provider]["used_quota"] += key.quota_used
    
    # 用户额度统计
    user_quotas = db.query(UserQuota).all()
    user_quota_stats = {}
    for quota in user_quotas:
        if quota.provider not in user_quota_stats:
            user_quota_stats[quota.provider] = {
                "total_users": 0,
                "allocated_quota": 0,
                "used_quota": 0
            }
        user_quota_stats[quota.provider]["total_users"] += 1
        user_quota_stats[quota.provider]["allocated_quota"] += quota.quota_total
        user_quota_stats[quota.provider]["used_quota"] += quota.quota_used
    
    return {
        "key_pool_stats": key_pool_stats,
        "user_quota_stats": user_quota_stats
    }
