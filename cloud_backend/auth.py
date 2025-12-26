"""用户认证模块"""
from datetime import datetime, timedelta
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from pydantic import BaseModel
from passlib.context import CryptContext
from jose import JWTError, jwt
import os

from database import get_db
from models import User, InviteCode

# JWT配置
SECRET_KEY = os.getenv("SECRET_KEY", "change-this-secret-key")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "10080"))

# 密码加密
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

# HTTP Bearer认证
security = HTTPBearer()

router = APIRouter()


# ============ Pydantic模型 ============

class RegisterRequest(BaseModel):
    username: str
    password: str
    email: Optional[str] = None
    invite_code: Optional[str] = None


class LoginRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: dict


class UserResponse(BaseModel):
    id: int
    username: str
    email: Optional[str]
    is_admin: bool
    created_at: Optional[str]


# ============ 工具函数 ============

def verify_password(plain_password: str, hashed_password: str) -> bool:
    """验证密码"""
    return pwd_context.verify(plain_password, hashed_password)


def get_password_hash(password: str) -> str:
    """生成密码哈希"""
    return pwd_context.hash(password)


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    """创建JWT Token"""
    to_encode = data.copy()
    if expires_delta:
        expire = datetime.utcnow() + expires_delta
    else:
        expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode.update({"exp": expire})
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt


def decode_token(token: str) -> dict:
    """解码JWT Token"""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except JWTError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="无效的认证凭证",
            headers={"WWW-Authenticate": "Bearer"},
        )


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db)
) -> int:
    """获取当前登录用户ID（依赖注入）"""
    token = credentials.credentials
    payload = decode_token(token)
    user_id: int = payload.get("sub")
    if user_id is None:
        raise HTTPException(status_code=401, detail="无效的认证凭证")
    
    # 验证用户是否存在
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=401, detail="用户不存在")
    if not user.is_active:
        raise HTTPException(status_code=403, detail="用户已被禁用")
    
    return user_id


def get_current_admin_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: Session = Depends(get_db)
) -> int:
    """获取当前管理员用户ID"""
    user_id = get_current_user(credentials, db)
    user = db.query(User).filter(User.id == user_id).first()
    if not user.is_admin:
        raise HTTPException(status_code=403, detail="需要管理员权限")
    return user_id


# ============ API路由 ============

@router.post("/register", response_model=TokenResponse)
async def register(
    request: RegisterRequest,
    db: Session = Depends(get_db)
):
    """用户注册"""
    # 检查用户名是否已存在
    existing_user = db.query(User).filter(User.username == request.username).first()
    if existing_user:
        raise HTTPException(status_code=400, detail="用户名已存在")
    
    # 检查邮箱是否已存在
    if request.email:
        existing_email = db.query(User).filter(User.email == request.email).first()
        if existing_email:
            raise HTTPException(status_code=400, detail="邮箱已被使用")
    
    # 验证邀请码（如果需要）
    if request.invite_code:
        invite = db.query(InviteCode).filter(InviteCode.code == request.invite_code).first()
        if not invite:
            raise HTTPException(status_code=400, detail="无效的邀请码")
        if not invite.enabled:
            raise HTTPException(status_code=400, detail="邀请码已禁用")
        if invite.used_count >= invite.max_uses:
            raise HTTPException(status_code=400, detail="邀请码已达到使用上限")
        
        # 增加使用次数
        invite.used_count += 1
    
    # 创建新用户
    hashed_password = get_password_hash(request.password)
    new_user = User(
        username=request.username,
        email=request.email,
        password_hash=hashed_password
    )
    db.add(new_user)
    db.flush()  # 获取ID但不提交
    
    # 生成唯一ID (格式：USER-00001)
    new_user.unique_id = f"USER-{new_user.id:05d}"
    
    db.commit()
    db.refresh(new_user)
    
    # 生成Token
    access_token = create_access_token(data={"sub": new_user.id})
    
    return {
        "access_token": access_token,
        "token_type": "bearer",
        "user": new_user.to_dict()
    }


@router.post("/login", response_model=TokenResponse)
async def login(
    request: LoginRequest,
    db: Session = Depends(get_db)
):
    """用户登录"""
    # 查找用户
    user = db.query(User).filter(User.username == request.username).first()
    if not user:
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    
    # 验证密码
    if not verify_password(request.password, user.password_hash):
        raise HTTPException(status_code=401, detail="用户名或密码错误")
    
    # 检查用户状态
    if not user.is_active:
        raise HTTPException(status_code=403, detail="用户已被禁用")
    
    # 生成Token
    access_token = create_access_token(data={"sub": user.id})
    
    return {
        "access_token": access_token,
        "token_type": "bearer",
        "user": user.to_dict()
    }


@router.get("/me", response_model=UserResponse)
async def get_current_user_info(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取当前用户信息"""
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="用户不存在")
    
    return UserResponse(**user.to_dict())


@router.post("/bootstrap-admin")
async def bootstrap_admin(
    request: RegisterRequest,
    db: Session = Depends(get_db)
):
    """
    创建首个管理员账号（仅在没有任何用户时可用）
    生产环境建议禁用此接口
    """
    # 检查是否已有用户
    user_count = db.query(User).count()
    if user_count > 0:
        raise HTTPException(status_code=403, detail="已存在用户，无法创建初始管理员")
    
    # 创建管理员
    hashed_password = get_password_hash(request.password)
    admin_user = User(
        username=request.username,
        email=request.email,
        password_hash=hashed_password,
        is_admin=True,
        user_level=99  # 管理员级别
    )
    db.add(admin_user)
    db.flush()
    
    # 生成唯一ID
    admin_user.unique_id = f"ADMIN-{admin_user.id:05d}"
    
    db.commit()
    db.refresh(admin_user)
    
    # 生成Token
    access_token = create_access_token(data={"sub": admin_user.id})
    
    return {
        "access_token": access_token,
        "token_type": "bearer",
        "user": admin_user.to_dict()
    }
