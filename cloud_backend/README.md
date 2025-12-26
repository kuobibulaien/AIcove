# MyGril Cloud Sync 云同步服务

精简的云同步后端，仅负责用户认证和数据同步，所有AI逻辑在Flutter客户端。

## 🎯 功能

- ✅ 用户注册/登录（JWT认证）
- ✅ 联系人/角色云同步
- ✅ 聊天消息云同步
- ✅ 用户设置云同步
- ✅ 管理后台（用户管理、邀请码）
- ✅ RESTful API

## 📦 技术栈

- **FastAPI** - 现代Web框架
- **SQLAlchemy** - ORM
- **SQLite** - 数据库（可换PostgreSQL）
- **JWT** - 认证
- **Docker** - 容器化部署

## 🚀 快速开始

### 方法1：直接运行（开发）

```bash
# 1. 安装依赖
pip install -r requirements.txt

# 2. 配置环境变量
cp .env.example .env
# 编辑.env，设置SECRET_KEY

# 3. 启动服务
# Linux/Mac
chmod +x start.sh
./start.sh

# Windows
.\start.ps1

# 或直接用Python
python main.py
```

访问: http://localhost:8000/docs (Swagger文档)

### 方法2：Docker（生产推荐）

```bash
# 1. 配置环境变量
cp .env.example .env
# 编辑.env

# 2. 启动
docker-compose up -d

# 3. 查看日志
docker-compose logs -f

# 4. 停止
docker-compose down
```

## 📖 API文档

启动后访问: http://localhost:8000/docs

### 主要端点

#### 认证
- `POST /api/v1/auth/register` - 注册
- `POST /api/v1/auth/login` - 登录
- `GET /api/v1/auth/me` - 获取当前用户信息
- `POST /api/v1/auth/bootstrap-admin` - 创建首个管理员

#### 数据同步
- `GET /api/v1/sync/contacts` - 获取联系人
- `POST /api/v1/sync/contacts` - 批量同步联系人
- `GET /api/v1/sync/messages` - 获取消息
- `POST /api/v1/sync/messages` - 批量同步消息
- `GET /api/v1/sync/settings` - 获取用户设置
- `PUT /api/v1/sync/settings` - 更新用户设置
- `GET /api/v1/sync/status` - 获取同步状态

#### 管理（需管理员权限）
- `POST /api/v1/admin/invites` - 创建邀请码
- `GET /api/v1/admin/invites` - 邀请码列表
- `GET /api/v1/admin/users` - 用户列表
- `GET /api/v1/admin/stats` - 系统统计

## 🔧 配置说明

### 环境变量（.env）

```env
# 服务器配置
HOST=0.0.0.0
PORT=8000

# 安全密钥（必须修改！）
SECRET_KEY=your-random-secret-key-here

# JWT过期时间（分钟）
ACCESS_TOKEN_EXPIRE_MINUTES=10080

# 数据库
DATABASE_URL=sqlite:///./data/sync.db

# CORS（生产环境改为具体域名）
ALLOWED_ORIGINS=*
```

## 🗄️ 数据库

默认使用SQLite，数据保存在 `data/sync.db`。

### 切换到PostgreSQL

修改 `.env`:
```env
DATABASE_URL=postgresql://user:password@localhost/mygril
```

## 📊 项目结构

```
cloud_backend/
├── main.py              # 主入口
├── database.py          # 数据库连接
├── models.py            # 数据模型
├── auth.py              # 认证模块
├── sync_api.py          # 同步API
├── admin_api.py         # 管理API
├── requirements.txt     # Python依赖
├── .env.example         # 环境变量示例
├── Dockerfile           # Docker镜像
├── docker-compose.yml   # Docker编排
└── README.md            # 本文档
```

## 🚢 部署到云服务器

### 使用Docker（推荐）

```bash
# 1. SSH连接到服务器
ssh user@your-server.com

# 2. 克隆代码
git clone your-repo.git
cd your-repo/cloud_backend

# 3. 配置环境
cp .env.example .env
nano .env  # 编辑配置

# 4. 启动服务
docker-compose up -d
```

### 配置Nginx反向代理

```nginx
server {
    listen 80;
    server_name api.yourdomain.com;
    
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### 申请SSL证书

```bash
sudo certbot --nginx -d api.yourdomain.com
```

## 🔐 安全建议

1. **修改SECRET_KEY**: 使用强随机字符串
2. **HTTPS**: 生产环境必须使用HTTPS
3. **CORS**: 限制允许的前端域名
4. **备份**: 定期备份数据库
5. **监控**: 配置日志和监控告警

## 📝 初始化管理员

首次部署后，创建管理员账号：

```bash
curl -X POST http://your-server:8000/api/v1/auth/bootstrap-admin \
  -H "Content-Type: application/json" \
  -d '{
    "username": "admin",
    "password": "your-strong-password",
    "email": "admin@example.com"
  }'
```

## 🐛 故障排查

### 服务无法启动
- 检查端口是否被占用: `lsof -i :8000`
- 查看日志: `docker-compose logs`

### 数据库连接错误
- 确认data目录有写权限
- 检查DATABASE_URL配置

### 认证失败
- 确认SECRET_KEY已设置且未改变
- 检查Token是否过期

## 📚 相关文档

- [FastAPI官方文档](https://fastapi.tiangolo.com/)
- [SQLAlchemy文档](https://docs.sqlalchemy.org/)
- [Docker文档](https://docs.docker.com/)

## 📄 许可证

MIT License
