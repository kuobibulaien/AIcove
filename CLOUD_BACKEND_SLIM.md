# 精简云服务后端设计方案

## 🎯 核心原则

**Flutter端（客户端）负责：**
- ✅ 所有AI对话逻辑
- ✅ API调用（OpenAI/Gemini等）
- ✅ 音频播放
- ✅ 本地数据存储
- ✅ UI交互

**云服务器（后端）只负责：**
- ✅ 用户认证（注册/登录/Token）
- ✅ 数据云同步（存储+分发）
- ✅ 管理后台（用户管理/统计）
- ✅ [可选] API Key分发（统一管理）

---

## 📦 精简后端架构

```
cloud_backend/                    # 新的精简后端
├── requirements.txt              # 最小依赖
├── .env.example
├── main.py                       # 入口文件（很简单）
├── database.py                   # 数据库连接
├── models.py                     # 数据模型
├── auth.py                       # 认证逻辑
├── sync_api.py                   # 同步API
└── admin_api.py                  # 管理API
```

### 最小依赖（requirements.txt）
```txt
fastapi==0.109.0
uvicorn[standard]==0.27.0
sqlalchemy==2.0.25
pydantic==2.5.3
pydantic-settings==2.1.0
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
python-multipart==0.0.6
```

## 🗄️ 数据库设计（精简版）

### 1. 用户表（复用现有）
```sql
-- 已存在，保留
users (id, username, password_hash, is_admin, created_at)
```

### 2. 联系人表
```sql
CREATE TABLE contacts (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    contact_id TEXT UNIQUE NOT NULL,  -- Flutter生成的UUID
    name TEXT NOT NULL,
    avatar_url TEXT,
    character_data TEXT,              -- JSON: 角色设定、system_prompt等
    is_deleted BOOLEAN DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_contacts_user ON contacts(user_id);
```

### 3. 消息表
```sql
CREATE TABLE messages (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    message_id TEXT UNIQUE NOT NULL,  -- Flutter生成的UUID
    contact_id TEXT NOT NULL,
    role TEXT NOT NULL,               -- 'user' or 'assistant'
    content TEXT NOT NULL,
    metadata TEXT,                    -- JSON: 音频URL、图片等
    is_deleted BOOLEAN DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
CREATE INDEX idx_messages_user_contact ON messages(user_id, contact_id);
CREATE INDEX idx_messages_created ON messages(created_at);
```

### 4. 用户配置表
```sql
CREATE TABLE user_settings (
    user_id INTEGER PRIMARY KEY,
    settings_json TEXT NOT NULL,      -- JSON: 所有用户配置
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

### 5. API Keys表（可选）
```sql
CREATE TABLE user_api_keys (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL,
    provider TEXT NOT NULL,           -- 'openai', 'gemini'
    api_key_encrypted TEXT NOT NULL,  -- 加密后的Key
    is_active BOOLEAN DEFAULT 1,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(id)
);
```

---

## 🔌 API接口设计（最小集）

### 基础路径
```
https://your-server.com/api/v1
```

### 1. 认证相关（复用现有）
```
POST   /auth/register          # 注册
POST   /auth/login             # 登录
GET    /auth/me                # 获取当前用户信息
```

### 2. 同步相关（新增）

#### 2.1 联系人同步
```
GET    /sync/contacts          # 获取所有联系人
POST   /sync/contacts          # 批量上传/更新联系人
DELETE /sync/contacts/{id}     # 删除联系人

# 请求示例
POST /sync/contacts
{
  "items": [
    {
      "contact_id": "uuid-123",
      "name": "小美",
      "avatar_url": "https://...",
      "character_data": {
        "system_prompt": "你是...",
        "personality": "温柔",
        ...
      },
      "updated_at": "2025-01-14T10:00:00Z"
    }
  ]
}

# 响应
{
  "synced": 1,
  "conflicts": [],  // 如果有冲突，返回冲突项
  "server_time": "2025-01-14T11:00:00Z"
}
```

#### 2.2 消息同步
```
GET    /sync/messages?contact_id={id}&since={timestamp}&limit=100
POST   /sync/messages          # 批量上传消息

# 增量拉取示例
GET /sync/messages?contact_id=uuid-123&since=2025-01-14T10:00:00Z

# 响应
{
  "messages": [
    {
      "message_id": "msg-456",
      "contact_id": "uuid-123",
      "role": "user",
      "content": "你好",
      "created_at": "2025-01-14T10:05:00Z"
    }
  ],
  "has_more": false
}
```

#### 2.3 用户设置同步
```
GET    /sync/settings          # 获取用户设置
PUT    /sync/settings          # 更新用户设置

# 请求示例
PUT /sync/settings
{
  "theme": "dark",
  "auto_play_tts": true,
  "default_provider": "openai",
  ...
}
```

#### 2.4 同步状态
```
GET    /sync/status            # 获取各类数据的同步状态

# 响应
{
  "contacts": {
    "count": 5,
    "last_updated": "2025-01-14T10:00:00Z"
  },
  "messages": {
    "count": 120,
    "last_updated": "2025-01-14T11:00:00Z"
  },
  "settings": {
    "last_updated": "2025-01-14T09:00:00Z"
  }
}
```

### 3. 管理相关（复用现有）
```
# 管理员接口（已存在）
POST   /admin/invites          # 创建邀请码
GET    /admin/invites          # 邀请码列表
GET    /admin/users            # 用户列表
```

---

## 💻 核心代码实现

### main.py（极简版）
```python
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from auth import router as auth_router
from sync_api import router as sync_router
from admin_api import router as admin_router
from database import init_db

app = FastAPI(title="MyGril Cloud Sync", version="1.0.0")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # 生产环境改为具体域名
    allow_methods=["*"],
    allow_headers=["*"],
)

# 初始化数据库
@app.on_event("startup")
async def startup():
    init_db()

# 路由
app.include_router(auth_router, prefix="/api/v1/auth", tags=["auth"])
app.include_router(sync_router, prefix="/api/v1/sync", tags=["sync"])
app.include_router(admin_router, prefix="/api/v1/admin", tags=["admin"])

@app.get("/health")
async def health():
    return {"status": "ok"}
```

### sync_api.py（同步API核心）
```python
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from typing import List
from datetime import datetime
from auth import get_current_user
from database import get_db
from models import Contact, Message, UserSettings
from pydantic import BaseModel

router = APIRouter()

class ContactSync(BaseModel):
    contact_id: str
    name: str
    avatar_url: str | None = None
    character_data: dict
    updated_at: datetime

class MessageSync(BaseModel):
    message_id: str
    contact_id: str
    role: str
    content: str
    metadata: dict | None = None
    created_at: datetime

# ============ 联系人同步 ============

@router.get("/contacts")
async def get_contacts(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取用户所有联系人"""
    contacts = db.query(Contact).filter(
        Contact.user_id == user_id,
        Contact.is_deleted == False
    ).all()
    return {"contacts": [c.to_dict() for c in contacts]}

@router.post("/contacts")
async def sync_contacts(
    items: List[ContactSync],
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """批量上传/更新联系人"""
    synced = 0
    conflicts = []
    
    for item in items:
        # 检查是否已存在
        existing = db.query(Contact).filter(
            Contact.user_id == user_id,
            Contact.contact_id == item.contact_id
        ).first()
        
        if existing:
            # 检查冲突（服务器版本更新）
            if existing.updated_at > item.updated_at:
                conflicts.append({
                    "contact_id": item.contact_id,
                    "server_version": existing.to_dict(),
                    "client_version": item.dict()
                })
                continue
            
            # 更新
            existing.name = item.name
            existing.avatar_url = item.avatar_url
            existing.character_data = item.character_data
            existing.updated_at = datetime.utcnow()
        else:
            # 新建
            new_contact = Contact(
                user_id=user_id,
                contact_id=item.contact_id,
                name=item.name,
                avatar_url=item.avatar_url,
                character_data=item.character_data
            )
            db.add(new_contact)
        
        synced += 1
    
    db.commit()
    return {
        "synced": synced,
        "conflicts": conflicts,
        "server_time": datetime.utcnow().isoformat()
    }

# ============ 消息同步 ============

@router.get("/messages")
async def get_messages(
    contact_id: str,
    since: datetime | None = None,
    limit: int = 100,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """增量获取消息"""
    query = db.query(Message).filter(
        Message.user_id == user_id,
        Message.contact_id == contact_id,
        Message.is_deleted == False
    )
    
    if since:
        query = query.filter(Message.created_at > since)
    
    messages = query.order_by(Message.created_at).limit(limit).all()
    
    return {
        "messages": [m.to_dict() for m in messages],
        "has_more": len(messages) == limit
    }

@router.post("/messages")
async def sync_messages(
    items: List[MessageSync],
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """批量上传消息"""
    synced = 0
    
    for item in items:
        # 检查是否已存在（避免重复）
        existing = db.query(Message).filter(
            Message.message_id == item.message_id
        ).first()
        
        if not existing:
            new_message = Message(
                user_id=user_id,
                message_id=item.message_id,
                contact_id=item.contact_id,
                role=item.role,
                content=item.content,
                metadata=item.metadata,
                created_at=item.created_at
            )
            db.add(new_message)
            synced += 1
    
    db.commit()
    return {"synced": synced}

# ============ 设置同步 ============

@router.get("/settings")
async def get_settings(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取用户设置"""
    settings = db.query(UserSettings).filter(
        UserSettings.user_id == user_id
    ).first()
    
    if not settings:
        return {"settings": {}}
    
    return {"settings": settings.settings_json}

@router.put("/settings")
async def update_settings(
    settings: dict,
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """更新用户设置"""
    user_settings = db.query(UserSettings).filter(
        UserSettings.user_id == user_id
    ).first()
    
    if user_settings:
        user_settings.settings_json = settings
        user_settings.updated_at = datetime.utcnow()
    else:
        user_settings = UserSettings(
            user_id=user_id,
            settings_json=settings
        )
        db.add(user_settings)
    
    db.commit()
    return {"status": "ok"}

# ============ 同步状态 ============

@router.get("/status")
async def sync_status(
    user_id: int = Depends(get_current_user),
    db: Session = Depends(get_db)
):
    """获取同步状态"""
    contacts = db.query(Contact).filter(
        Contact.user_id == user_id,
        Contact.is_deleted == False
    )
    messages = db.query(Message).filter(
        Message.user_id == user_id,
        Message.is_deleted == False
    )
    settings = db.query(UserSettings).filter(
        UserSettings.user_id == user_id
    ).first()
    
    return {
        "contacts": {
            "count": contacts.count(),
            "last_updated": contacts.order_by(
                Contact.updated_at.desc()
            ).first().updated_at if contacts.first() else None
        },
        "messages": {
            "count": messages.count(),
            "last_updated": messages.order_by(
                Message.created_at.desc()
            ).first().created_at if messages.first() else None
        },
        "settings": {
            "last_updated": settings.updated_at if settings else None
        }
    }
```

---

## 🚀 部署方案（超简单）

### 方案A：直接运行（开发/小规模）
```bash
# 在你的云服务器上
git clone your-repo.git
cd cloud_backend

# 安装依赖
pip3 install -r requirements.txt

# 配置环境变量
cat > .env << EOF
SECRET_KEY=your-random-secret-key-here
DATABASE_URL=sqlite:///./sync.db
EOF

# 运行
uvicorn main:app --host 0.0.0.0 --port 8000
```

### 方案B：使用Systemd（自动重启）
```ini
# /etc/systemd/system/mygril-sync.service
[Unit]
Description=MyGril Cloud Sync Service
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/cloud_backend
Environment="PATH=/usr/bin:/usr/local/bin"
ExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
```

启动：
```bash
sudo systemctl enable mygril-sync
sudo systemctl start mygril-sync
```

### 方案C：Docker（最简单）
```dockerfile
# Dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

```bash
docker build -t mygril-sync .
docker run -d -p 8000:8000 \
  -e SECRET_KEY=your-secret \
  -v $(pwd)/data:/app/data \
  --name mygril-sync \
  --restart unless-stopped \
  mygril-sync
```

### Nginx反向代理（HTTPS）
```nginx
server {
    listen 80;
    server_name api.yourdomain.com;
    
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

申请SSL证书：
```bash
sudo certbot --nginx -d api.yourdomain.com
```

---

## 📱 Flutter端实现要点

### 1. 同步时机
```dart
// 自动同步场景
- 应用启动时：全量同步一次
- 用户登录后：立即同步
- 数据变更后：延迟5秒自动同步（防抖）
- 定时同步：每5分钟一次（后台）
- 应用进入前台：检查并同步

// 手动同步
- 下拉刷新
- 设置页"立即同步"按钮
```

### 2. 冲突处理策略
```dart
// 简单字段（名字、头像）：服务器版本优先
if (serverUpdatedAt > localUpdatedAt) {
  // 使用服务器版本
  local.update(serverData);
}

// 消息：仅追加，不删除
// 使用message_id去重，确保不重复插入

// 设置：合并策略
final merged = {...localSettings, ...serverSettings};
```

### 3. 离线支持
```dart
// 所有写操作先写本地，标记为"未同步"
await db.insert(contact.copyWith(isSynced: false));

// 定期上传未同步数据
final unsynced = await db.getUnsyncedContacts();
if (unsynced.isNotEmpty) {
  await api.syncContacts(unsynced);
  await db.markAsSynced(unsynced);
}
```

---

## 🎯 迁移方案（从当前后端）

### 选项1：完全替换（推荐）
1. 创建新的 `cloud_backend/` 目录
2. 只复用 `backend/app/routers/auth.py` 和 `admin.py`
3. 新增 `sync_api.py`
4. 删除所有Agent、MCP、Chat相关代码

### 选项2：保留但禁用
1. 在 `backend/app/main.py` 中注释掉冗余路由
2. 只保留 auth、admin、新增sync路由
3. 后续逐步清理

### 选项3：双版本共存（测试期）
1. 保留现有backend（8000端口）用于开发测试
2. 新建cloud_backend（8001端口）用于云同步
3. Flutter可配置连接哪个后端
4. 测试稳定后切换

---

## 📊 资源需求（云服务器）

### 最小配置
- CPU: 1核
- 内存: 1GB
- 存储: 20GB
- 带宽: 1Mbps
- **月费用：30-60元**（阿里云/腾讯云轻量服务器）

### 用户量估算
- 1000活跃用户
- 每人100条消息
- 每人5个联系人
- **数据库大小：约50MB**
- **流量：约1-2GB/月**

完全够用！

---

## ✅ 总结对比

| 项目 | 原后端 | 新云服务后端 |
|------|--------|-------------|
| 代码行数 | ~5000行 | ~500行 |
| 依赖包数 | 30+ | 8 |
| 启动内存 | ~300MB | ~50MB |
| 功能范围 | 全栈（AI+同步） | 仅云同步 |
| 维护难度 | 高 | 低 |
| 部署成本 | 高（需GPU？） | 低（最小配置） |

**推荐方案：创建新的精简云服务后端！**
