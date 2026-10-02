"""用户认证模块"""
from datetime import datetime, timedelta
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.orm import Session
from pydantic import BaseModel
import bcrypt
from jose import JWTError, jwt
import os

from database import get_db
from models import User

# JWT配置
SECRET_KEY = os.getenv("SECRET_KEY", "change-this-secret-key")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "10080"))
PERSISTENT_SESSION_USER_IDS = frozenset(
    int(value.strip())
    for value in os.getenv("PERSISTENT_SESSION_USER_IDS", "").split(',')
    if value.strip()
)

# 密码加密
# Existing bcrypt hashes remain compatible with the direct bcrypt API.

# HTTP Bearer认证
security = HTTPBearer()

router = APIRouter()


# ============ Pydantic模型 ============

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
    unique_id: Optional[str] = None
    email: Optional[str]
    is_admin: bool
    created_at: Optional[str]


# ============ 工具函数 ============

def verify_password(plain_password: str, hashed_password: str) -> bool:
    """验证密码"""
    try:
        return bcrypt.checkpw(plain_password.encode('utf-8')[:72], hashed_password.encode('ascii'))
    except (ValueError, TypeError, UnicodeError):
        return False


def get_password_hash(password: str, *, minimum_bytes: int = 8) -> str:
    """生成密码哈希"""
    encoded = password.encode('utf-8')
    if minimum_bytes not in (6, 8):
        raise ValueError("Unsupported password policy")
    if not minimum_bytes <= len(encoded) <= 72:
        raise HTTPException(422, detail=f"Password must contain {minimum_bytes} to 72 UTF-8 bytes")
    return bcrypt.hashpw(encoded, bcrypt.gensalt()).decode('ascii')


def create_access_token(data: dict, expires_delta: Optional[timedelta] = None) -> str:
    """创建JWT Token"""
    to_encode = data.copy()
    if 'sub' in to_encode:
        to_encode['sub'] = str(to_encode['sub'])
    if expires_delta is not None:
        expire = datetime.utcnow() + expires_delta
        to_encode["exp"] = expire
    elif to_encode.get('sub') not in {str(user_id) for user_id in PERSISTENT_SESSION_USER_IDS}:
        expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
        to_encode["exp"] = expire
    else:
        # Explicitly configured accounts retain their session across long
        # offline periods. Every request still checks the account's active flag.
        to_encode.pop("exp", None)
    encoded_jwt = jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)
    return encoded_jwt


def decode_token(token: str) -> dict:
    """解码JWT Token"""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM], options={'verify_sub': False})
        subject = payload.get('sub')
        if isinstance(subject, bool) or not str(subject).isdigit() or int(subject) <= 0:
            raise JWTError('Invalid subject')
        payload['sub'] = str(subject)
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


@router.post("/refresh", response_model=TokenResponse)
async def refresh_access_token(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """用仍有效的Token换取新Token（滑动续期，过期后必须重新登录）"""
    user = db.query(User).filter(User.id == user_id).first()
    return {
        "access_token": create_access_token(data={"sub": user.id}),
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
