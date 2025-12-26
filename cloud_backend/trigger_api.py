"""
云触发器API
提供自动化任务触发功能
支持定时触发、事件触发、条件触发
"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import func, desc
from typing import List, Optional, Dict, Any
from datetime import datetime, timezone
from pydantic import BaseModel, Field
import json

from database import get_db
from auth import get_current_user
from models import User, CloudTrigger, TriggerExecutionLog

router = APIRouter()


# ============ Pydantic Models ============

class TriggerCreate(BaseModel):
    """创建触发器请求"""
    trigger_name: str = Field(..., min_length=1, max_length=100, description="触发器名称")
    trigger_type: str = Field(..., description="触发器类型: schedule/event/condition")
    trigger_config: Dict[str, Any] = Field(..., description="触发条件配置")
    action_config: Dict[str, Any] = Field(..., description="触发动作配置")


class TriggerUpdate(BaseModel):
    """更新触发器请求"""
    trigger_name: Optional[str] = Field(None, min_length=1, max_length=100)
    trigger_config: Optional[Dict[str, Any]] = None
    action_config: Optional[Dict[str, Any]] = None
    is_active: Optional[bool] = None


class TriggerInfo(BaseModel):
    """触发器信息响应"""
    id: int
    trigger_name: str
    trigger_type: str
    trigger_config: Dict[str, Any]
    action_config: Dict[str, Any]
    is_active: bool
    last_triggered_at: Optional[datetime]
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class ExecutionLogInfo(BaseModel):
    """执行日志信息"""
    id: int
    trigger_id: int
    status: str
    execution_time_ms: int
    result_message: Optional[str]
    error_message: Optional[str]
    executed_at: datetime

    class Config:
        from_attributes = True


class TriggerStats(BaseModel):
    """触发器统计"""
    total_triggers: int
    active_triggers: int
    total_executions: int
    successful_executions: int
    failed_executions: int


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


def validate_trigger_type(trigger_type: str):
    """验证触发器类型"""
    valid_types = ["schedule", "event", "condition"]
    if trigger_type not in valid_types:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"无效的触发器类型，支持的类型: {', '.join(valid_types)}"
        )


def validate_trigger_config(trigger_type: str, config: Dict[str, Any]):
    """验证触发器配置"""
    if trigger_type == "schedule":
        if "cron" not in config:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="定时触发器需要提供 cron 表达式"
            )
    elif trigger_type == "event":
        if "event_type" not in config:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="事件触发器需要提供 event_type"
            )
    elif trigger_type == "condition":
        if "condition_type" not in config:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="条件触发器需要提供 condition_type"
            )


def validate_action_config(config: Dict[str, Any]):
    """验证动作配置"""
    if "action_type" not in config:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="动作配置需要提供 action_type"
        )


# ============ User Endpoints ============

@router.post("/create", response_model=TriggerInfo, status_code=status.HTTP_201_CREATED)
async def create_trigger(
    trigger_data: TriggerCreate,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    创建云触发器
    - 需要 Level 3+ 权限
    - 支持三种触发类型：schedule（定时）、event（事件）、condition（条件）
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 3)
    check_membership_expiry(user)

    # 验证触发器配置
    validate_trigger_type(trigger_data.trigger_type)
    validate_trigger_config(trigger_data.trigger_type, trigger_data.trigger_config)
    validate_action_config(trigger_data.action_config)

    # 创建触发器
    new_trigger = CloudTrigger(
        user_id=user_id,
        trigger_name=trigger_data.trigger_name,
        trigger_type=trigger_data.trigger_type,
        trigger_config=json.dumps(trigger_data.trigger_config),
        action_config=json.dumps(trigger_data.action_config),
        is_active=True
    )

    db.add(new_trigger)
    db.commit()
    db.refresh(new_trigger)

    return TriggerInfo(**new_trigger.to_dict())


@router.get("/list", response_model=List[TriggerInfo])
async def list_triggers(
    trigger_type: Optional[str] = None,
    is_active: Optional[bool] = None,
    skip: int = 0,
    limit: int = 50,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    获取用户的触发器列表
    - 可按类型和状态筛选
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 3)

    query = db.query(CloudTrigger).filter(CloudTrigger.user_id == user_id)

    if trigger_type:
        query = query.filter(CloudTrigger.trigger_type == trigger_type)
    if is_active is not None:
        query = query.filter(CloudTrigger.is_active == is_active)

    triggers = query.order_by(desc(CloudTrigger.created_at)).offset(skip).limit(limit).all()

    return [TriggerInfo(**t.to_dict()) for t in triggers]


@router.get("/{trigger_id}", response_model=TriggerInfo)
async def get_trigger(
    trigger_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取触发器详情"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 3)

    trigger = db.query(CloudTrigger).filter(
        CloudTrigger.id == trigger_id,
        CloudTrigger.user_id == user_id
    ).first()

    if not trigger:
        raise HTTPException(status_code=404, detail="触发器不存在")

    return TriggerInfo(**trigger.to_dict())


@router.put("/{trigger_id}", response_model=TriggerInfo)
async def update_trigger(
    trigger_id: int,
    trigger_update: TriggerUpdate,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    更新触发器配置
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 3)
    check_membership_expiry(user)

    trigger = db.query(CloudTrigger).filter(
        CloudTrigger.id == trigger_id,
        CloudTrigger.user_id == user_id
    ).first()

    if not trigger:
        raise HTTPException(status_code=404, detail="触发器不存在")

    # 更新字段
    if trigger_update.trigger_name is not None:
        trigger.trigger_name = trigger_update.trigger_name

    if trigger_update.trigger_config is not None:
        validate_trigger_config(trigger.trigger_type, trigger_update.trigger_config)
        trigger.trigger_config = json.dumps(trigger_update.trigger_config)

    if trigger_update.action_config is not None:
        validate_action_config(trigger_update.action_config)
        trigger.action_config = json.dumps(trigger_update.action_config)

    if trigger_update.is_active is not None:
        trigger.is_active = trigger_update.is_active

    db.commit()
    db.refresh(trigger)

    return TriggerInfo(**trigger.to_dict())


@router.delete("/{trigger_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_trigger(
    trigger_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """删除触发器"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 3)

    trigger = db.query(CloudTrigger).filter(
        CloudTrigger.id == trigger_id,
        CloudTrigger.user_id == user_id
    ).first()

    if not trigger:
        raise HTTPException(status_code=404, detail="触发器不存在")

    db.delete(trigger)
    db.commit()

    return None


@router.post("/{trigger_id}/toggle", response_model=TriggerInfo)
async def toggle_trigger(
    trigger_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    切换触发器启用/禁用状态
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 3)

    trigger = db.query(CloudTrigger).filter(
        CloudTrigger.id == trigger_id,
        CloudTrigger.user_id == user_id
    ).first()

    if not trigger:
        raise HTTPException(status_code=404, detail="触发器不存在")

    trigger.is_active = not trigger.is_active
    db.commit()
    db.refresh(trigger)

    return TriggerInfo(**trigger.to_dict())


@router.get("/{trigger_id}/logs", response_model=List[ExecutionLogInfo])
async def get_trigger_logs(
    trigger_id: int,
    skip: int = 0,
    limit: int = 50,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    获取触发器执行日志
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 3)

    # 验证触发器所属
    trigger = db.query(CloudTrigger).filter(
        CloudTrigger.id == trigger_id,
        CloudTrigger.user_id == user_id
    ).first()

    if not trigger:
        raise HTTPException(status_code=404, detail="触发器不存在")

    logs = db.query(TriggerExecutionLog).filter(
        TriggerExecutionLog.trigger_id == trigger_id
    ).order_by(
        desc(TriggerExecutionLog.executed_at)
    ).offset(skip).limit(limit).all()

    return [ExecutionLogInfo(**log.to_dict()) for log in logs]


@router.get("/stats/my", response_model=TriggerStats)
async def get_my_trigger_stats(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    获取当前用户的触发器统计信息
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 3)

    # 触发器统计
    total_triggers = db.query(func.count(CloudTrigger.id)).filter(
        CloudTrigger.user_id == user_id
    ).scalar() or 0

    active_triggers = db.query(func.count(CloudTrigger.id)).filter(
        CloudTrigger.user_id == user_id,
        CloudTrigger.is_active == True
    ).scalar() or 0

    # 执行记录统计
    total_executions = db.query(func.count(TriggerExecutionLog.id)).filter(
        TriggerExecutionLog.user_id == user_id
    ).scalar() or 0

    successful_executions = db.query(func.count(TriggerExecutionLog.id)).filter(
        TriggerExecutionLog.user_id == user_id,
        TriggerExecutionLog.status == "success"
    ).scalar() or 0

    failed_executions = db.query(func.count(TriggerExecutionLog.id)).filter(
        TriggerExecutionLog.user_id == user_id,
        TriggerExecutionLog.status == "failed"
    ).scalar() or 0

    return TriggerStats(
        total_triggers=total_triggers,
        active_triggers=active_triggers,
        total_executions=total_executions,
        successful_executions=successful_executions,
        failed_executions=failed_executions
    )


# ============ Admin Endpoints ============

@router.get("/admin/overview", response_model=dict)
async def get_triggers_overview(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    管理员：获取所有触发器的概览统计
    """
    admin = db.query(User).filter(User.id == user_id).first()
    if not admin or admin.user_level != 99:
        raise HTTPException(status_code=403, detail="需要管理员权限")

    # 总体统计
    total_triggers = db.query(func.count(CloudTrigger.id)).scalar() or 0
    active_triggers = db.query(func.count(CloudTrigger.id)).filter(
        CloudTrigger.is_active == True
    ).scalar() or 0

    # 按类型统计
    type_stats = db.query(
        CloudTrigger.trigger_type,
        func.count(CloudTrigger.id).label('count')
    ).group_by(CloudTrigger.trigger_type).all()

    # 执行统计
    total_executions = db.query(func.count(TriggerExecutionLog.id)).scalar() or 0

    execution_stats = db.query(
        TriggerExecutionLog.status,
        func.count(TriggerExecutionLog.id).label('count')
    ).group_by(TriggerExecutionLog.status).all()

    return {
        "total_triggers": total_triggers,
        "active_triggers": active_triggers,
        "trigger_types": {stat.trigger_type: stat.count for stat in type_stats},
        "total_executions": total_executions,
        "execution_status": {stat.status: stat.count for stat in execution_stats}
    }


@router.get("/admin/user/{unique_id}", response_model=List[TriggerInfo])
async def get_user_triggers_by_admin(
    unique_id: str,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    管理员：查看指定用户的所有触发器
    """
    admin = db.query(User).filter(User.id == user_id).first()
    if not admin or admin.user_level != 99:
        raise HTTPException(status_code=403, detail="需要管理员权限")

    target_user = db.query(User).filter(User.unique_id == unique_id).first()
    if not target_user:
        raise HTTPException(status_code=404, detail="用户不存在")

    triggers = db.query(CloudTrigger).filter(
        CloudTrigger.user_id == target_user.id
    ).order_by(
        desc(CloudTrigger.created_at)
    ).all()

    return [TriggerInfo(**t.to_dict()) for t in triggers]
