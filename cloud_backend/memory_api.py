"""
云记忆库API
提供长期记忆存储、检索和管理功能
支持关键词搜索和语义搜索（需要向量嵌入）
"""
from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session
from sqlalchemy import func, desc, or_
from typing import List, Optional, Dict, Any
from datetime import datetime, timezone
from pydantic import BaseModel, Field
import json
import time

from database import get_db
from auth import get_current_user
from models import User, MemoryStore, MemorySearchHistory

router = APIRouter()


# ============ Pydantic Models ============

class MemoryCreate(BaseModel):
    """创建记忆请求"""
    memory_type: str = Field(..., description="记忆类型: conversation/fact/preference/custom")
    memory_key: str = Field(..., min_length=1, max_length=200, description="记忆标识")
    memory_content: str = Field(..., description="记忆内容")
    contact_id: Optional[str] = Field(None, description="关联的联系人ID")
    embedding_vector: Optional[List[float]] = Field(None, description="向量嵌入（可选）")
    metadata: Optional[Dict[str, Any]] = Field(None, description="元数据")
    importance_score: int = Field(5, ge=1, le=10, description="重要性评分 1-10")


class MemoryUpdate(BaseModel):
    """更新记忆请求"""
    memory_content: Optional[str] = None
    embedding_vector: Optional[List[float]] = None
    metadata: Optional[Dict[str, Any]] = None
    importance_score: Optional[int] = Field(None, ge=1, le=10)


class MemoryInfo(BaseModel):
    """记忆信息响应"""
    id: int
    contact_id: Optional[str]
    memory_type: str
    memory_key: str
    memory_content: str
    metadata: Dict[str, Any]
    importance_score: int
    access_count: int
    last_accessed_at: Optional[datetime]
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class MemorySearchRequest(BaseModel):
    """记忆搜索请求"""
    query: str = Field(..., min_length=1, description="搜索查询")
    search_type: str = Field("keyword", description="搜索类型: keyword/semantic")
    memory_type: Optional[str] = Field(None, description="筛选记忆类型")
    contact_id: Optional[str] = Field(None, description="筛选联系人")
    min_importance: Optional[int] = Field(None, ge=1, le=10, description="最低重要性")
    limit: int = Field(10, ge=1, le=100, description="返回结果数量")
    query_embedding: Optional[List[float]] = Field(None, description="查询向量（语义搜索需要）")


class MemorySearchResult(BaseModel):
    """搜索结果"""
    memories: List[MemoryInfo]
    total_results: int
    search_time_ms: int


class MemoryStats(BaseModel):
    """记忆统计"""
    total_memories: int
    by_type: Dict[str, int]
    by_contact: Dict[str, int]
    total_storage_size: int  # 字节
    most_accessed: List[MemoryInfo]


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


def cosine_similarity(vec1: List[float], vec2: List[float]) -> float:
    """计算余弦相似度"""
    if len(vec1) != len(vec2):
        return 0.0

    dot_product = sum(a * b for a, b in zip(vec1, vec2))
    magnitude1 = sum(a * a for a in vec1) ** 0.5
    magnitude2 = sum(b * b for b in vec2) ** 0.5

    if magnitude1 == 0 or magnitude2 == 0:
        return 0.0

    return dot_product / (magnitude1 * magnitude2)


# ============ User Endpoints ============

@router.post("/create", response_model=MemoryInfo, status_code=status.HTTP_201_CREATED)
async def create_memory(
    memory_data: MemoryCreate,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    创建新记忆
    - 需要 Level 4+ 权限
    - 支持可选的向量嵌入
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 4)
    check_membership_expiry(user)

    # 验证记忆类型
    valid_types = ["conversation", "fact", "preference", "custom"]
    if memory_data.memory_type not in valid_types:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"无效的记忆类型，支持: {', '.join(valid_types)}"
        )

    # 准备向量数据
    embedding_json = None
    if memory_data.embedding_vector:
        embedding_json = json.dumps(memory_data.embedding_vector)

    # 准备元数据
    metadata_json = None
    if memory_data.metadata:
        metadata_json = json.dumps(memory_data.metadata)

    # 创建记忆
    new_memory = MemoryStore(
        user_id=user_id,
        contact_id=memory_data.contact_id,
        memory_type=memory_data.memory_type,
        memory_key=memory_data.memory_key,
        memory_content=memory_data.memory_content,
        embedding_vector=embedding_json,
        metadata=metadata_json,
        importance_score=memory_data.importance_score
    )

    db.add(new_memory)
    db.commit()
    db.refresh(new_memory)

    return MemoryInfo(**new_memory.to_dict())


@router.get("/list", response_model=List[MemoryInfo])
async def list_memories(
    memory_type: Optional[str] = None,
    contact_id: Optional[str] = None,
    min_importance: Optional[int] = None,
    skip: int = 0,
    limit: int = 50,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    获取用户的记忆列表
    - 可按类型、联系人、重要性筛选
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 4)

    query = db.query(MemoryStore).filter(MemoryStore.user_id == user_id)

    if memory_type:
        query = query.filter(MemoryStore.memory_type == memory_type)
    if contact_id:
        query = query.filter(MemoryStore.contact_id == contact_id)
    if min_importance:
        query = query.filter(MemoryStore.importance_score >= min_importance)

    memories = query.order_by(
        desc(MemoryStore.importance_score),
        desc(MemoryStore.updated_at)
    ).offset(skip).limit(limit).all()

    return [MemoryInfo(**m.to_dict()) for m in memories]


@router.get("/{memory_id}", response_model=MemoryInfo)
async def get_memory(
    memory_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    获取记忆详情
    - 自动更新访问次数和最后访问时间
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 4)

    memory = db.query(MemoryStore).filter(
        MemoryStore.id == memory_id,
        MemoryStore.user_id == user_id
    ).first()

    if not memory:
        raise HTTPException(status_code=404, detail="记忆不存在")

    # 更新访问统计
    memory.access_count += 1
    memory.last_accessed_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(memory)

    return MemoryInfo(**memory.to_dict())


@router.put("/{memory_id}", response_model=MemoryInfo)
async def update_memory(
    memory_id: int,
    memory_update: MemoryUpdate,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """更新记忆内容"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 4)
    check_membership_expiry(user)

    memory = db.query(MemoryStore).filter(
        MemoryStore.id == memory_id,
        MemoryStore.user_id == user_id
    ).first()

    if not memory:
        raise HTTPException(status_code=404, detail="记忆不存在")

    # 更新字段
    if memory_update.memory_content is not None:
        memory.memory_content = memory_update.memory_content

    if memory_update.embedding_vector is not None:
        memory.embedding_vector = json.dumps(memory_update.embedding_vector)

    if memory_update.metadata is not None:
        memory.metadata = json.dumps(memory_update.metadata)

    if memory_update.importance_score is not None:
        memory.importance_score = memory_update.importance_score

    db.commit()
    db.refresh(memory)

    return MemoryInfo(**memory.to_dict())


@router.delete("/{memory_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_memory(
    memory_id: int,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """删除记忆"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 4)

    memory = db.query(MemoryStore).filter(
        MemoryStore.id == memory_id,
        MemoryStore.user_id == user_id
    ).first()

    if not memory:
        raise HTTPException(status_code=404, detail="记忆不存在")

    db.delete(memory)
    db.commit()

    return None


@router.post("/search", response_model=MemorySearchResult)
async def search_memories(
    search_request: MemorySearchRequest,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """
    搜索记忆
    - 支持关键词搜索和语义搜索
    - 语义搜索需要提供查询向量
    """
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 4)

    start_time = time.time()

    if search_request.search_type == "keyword":
        # 关键词搜索
        query = db.query(MemoryStore).filter(MemoryStore.user_id == user_id)

        # 应用筛选条件
        if search_request.memory_type:
            query = query.filter(MemoryStore.memory_type == search_request.memory_type)
        if search_request.contact_id:
            query = query.filter(MemoryStore.contact_id == search_request.contact_id)
        if search_request.min_importance:
            query = query.filter(MemoryStore.importance_score >= search_request.min_importance)

        # 关键词匹配
        search_pattern = f"%{search_request.query}%"
        query = query.filter(
            or_(
                MemoryStore.memory_key.like(search_pattern),
                MemoryStore.memory_content.like(search_pattern)
            )
        )

        memories = query.order_by(
            desc(MemoryStore.importance_score),
            desc(MemoryStore.access_count)
        ).limit(search_request.limit).all()

    elif search_request.search_type == "semantic":
        # 语义搜索（基于向量相似度）
        if not search_request.query_embedding:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="语义搜索需要提供 query_embedding"
            )

        # 获取所有有向量的记忆
        query = db.query(MemoryStore).filter(
            MemoryStore.user_id == user_id,
            MemoryStore.embedding_vector.isnot(None)
        )

        # 应用筛选条件
        if search_request.memory_type:
            query = query.filter(MemoryStore.memory_type == search_request.memory_type)
        if search_request.contact_id:
            query = query.filter(MemoryStore.contact_id == search_request.contact_id)
        if search_request.min_importance:
            query = query.filter(MemoryStore.importance_score >= search_request.min_importance)

        all_memories = query.all()

        # 计算相似度并排序
        memories_with_similarity = []
        for memory in all_memories:
            try:
                memory_vector = json.loads(memory.embedding_vector)
                similarity = cosine_similarity(search_request.query_embedding, memory_vector)
                memories_with_similarity.append((memory, similarity))
            except:
                continue

        # 按相似度排序
        memories_with_similarity.sort(key=lambda x: x[1], reverse=True)
        memories = [m[0] for m in memories_with_similarity[:search_request.limit]]

    else:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="无效的搜索类型，支持: keyword, semantic"
        )

    # 记录搜索历史
    search_time_ms = int((time.time() - start_time) * 1000)
    search_history = MemorySearchHistory(
        user_id=user_id,
        search_query=search_request.query,
        search_type=search_request.search_type,
        results_count=len(memories),
        search_time_ms=search_time_ms
    )
    db.add(search_history)
    db.commit()

    return MemorySearchResult(
        memories=[MemoryInfo(**m.to_dict()) for m in memories],
        total_results=len(memories),
        search_time_ms=search_time_ms
    )


@router.get("/stats/my", response_model=MemoryStats)
async def get_my_memory_stats(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取当前用户的记忆统计"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")

    check_user_level(user, 4)

    # 总数
    total_memories = db.query(func.count(MemoryStore.id)).filter(
        MemoryStore.user_id == user_id
    ).scalar() or 0

    # 按类型统计
    type_stats = db.query(
        MemoryStore.memory_type,
        func.count(MemoryStore.id).label('count')
    ).filter(
        MemoryStore.user_id == user_id
    ).group_by(MemoryStore.memory_type).all()

    by_type = {stat.memory_type: stat.count for stat in type_stats}

    # 按联系人统计
    contact_stats = db.query(
        MemoryStore.contact_id,
        func.count(MemoryStore.id).label('count')
    ).filter(
        MemoryStore.user_id == user_id,
        MemoryStore.contact_id.isnot(None)
    ).group_by(MemoryStore.contact_id).all()

    by_contact = {stat.contact_id: stat.count for stat in contact_stats if stat.contact_id}

    # 存储大小估算（字符数）
    total_size = db.query(
        func.sum(func.length(MemoryStore.memory_content))
    ).filter(MemoryStore.user_id == user_id).scalar() or 0

    # 最常访问的记忆
    most_accessed = db.query(MemoryStore).filter(
        MemoryStore.user_id == user_id
    ).order_by(
        desc(MemoryStore.access_count)
    ).limit(5).all()

    return MemoryStats(
        total_memories=total_memories,
        by_type=by_type,
        by_contact=by_contact,
        total_storage_size=int(total_size),
        most_accessed=[MemoryInfo(**m.to_dict()) for m in most_accessed]
    )


# ============ Admin Endpoints ============

@router.get("/admin/overview", response_model=dict)
async def get_memory_overview(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """管理员：获取所有记忆的概览统计"""
    admin = db.query(User).filter(User.id == user_id).first()
    if not admin or admin.user_level != 99:
        raise HTTPException(status_code=403, detail="需要管理员权限")

    total_memories = db.query(func.count(MemoryStore.id)).scalar() or 0

    users_with_memories = db.query(
        func.count(func.distinct(MemoryStore.user_id))
    ).scalar() or 0

    total_storage = db.query(
        func.sum(func.length(MemoryStore.memory_content))
    ).scalar() or 0

    # 按类型统计
    type_stats = db.query(
        MemoryStore.memory_type,
        func.count(MemoryStore.id).label('count')
    ).group_by(MemoryStore.memory_type).all()

    return {
        "total_memories": total_memories,
        "users_with_memories": users_with_memories,
        "total_storage_bytes": int(total_storage),
        "by_type": {stat.memory_type: stat.count for stat in type_stats}
    }
