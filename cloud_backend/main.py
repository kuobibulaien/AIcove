"""MyGril 云同步服务 - 主入口"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
import os

from database import init_db
from auth import router as auth_router
from sync_api import router as sync_router
from sync_api_v2 import router as sync_v2_router  # 新版同步 API
from admin_api import router as admin_router
from key_distribution import router as key_router
from backup_api import router as backup_router
from trigger_api import router as trigger_router
from memory_api import router as memory_router

# 创建FastAPI应用
app = FastAPI(
    title="MyGril Cloud Sync",
    description="MyGril AI女友助手 - 云同步服务",
    version="1.0.0"
)

# CORS配置
allowed_origins = os.getenv("ALLOWED_ORIGINS", "*")
if allowed_origins == "*":
    origins = ["*"]
else:
    origins = [origin.strip() for origin in allowed_origins.split(",")]

app.add_middleware(
    CORSMiddleware,
    allow_origins=origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# 启动事件：初始化数据库
@app.on_event("startup")
async def startup_event():
    """应用启动时执行"""
    print("🚀 正在启动 MyGril 云同步服务...")
    try:
        init_db()
        print("✅ 数据库初始化成功")
    except Exception as e:
        print(f"❌ 数据库初始化失败: {e}")
    print(f"🌐 CORS允许的源: {origins}")
    print("✨ 服务已启动！")


# 根路径
@app.get("/")
async def root():
    """服务根路径"""
    return {
        "service": "MyGril Cloud Sync",
        "version": "1.0.0",
        "status": "running",
        "docs": "/docs",
        "endpoints": {
            "health": "/health",
            "auth": "/api/v1/auth",
            "sync": "/api/v1/sync",
            "sync_v2": "/api/v1/sync/v2",  # 新版同步 API
            "keys": "/api/v1/keys",
            "backup": "/api/v1/backup",
            "triggers": "/api/v1/triggers",
            "memory": "/api/v1/memory",
            "admin": "/api/v1/admin"
        }
    }


# 健康检查
@app.get("/health")
async def health_check():
    """健康检查端点"""
    return {"status": "ok", "service": "MyGril Cloud Sync"}


# 注册路由
app.include_router(auth_router, prefix="/api/v1/auth", tags=["认证"])
app.include_router(sync_router, prefix="/api/v1/sync", tags=["数据同步(旧版)"])
app.include_router(sync_v2_router, prefix="/api/v1/sync", tags=["数据同步(v2)"])  # 新版挂载在 /api/v1/sync/v2
app.include_router(key_router, prefix="/api/v1/keys", tags=["Key分发"])
app.include_router(backup_router, prefix="/api/v1/backup", tags=["数据备份"])
app.include_router(trigger_router, prefix="/api/v1/triggers", tags=["云触发器"])
app.include_router(memory_router, prefix="/api/v1/memory", tags=["云记忆库"])
app.include_router(admin_router, prefix="/api/v1/admin", tags=["管理"])


# 全局异常处理
@app.exception_handler(Exception)
async def global_exception_handler(request, exc):
    """全局异常处理器"""
    return JSONResponse(
        status_code=500,
        content={
            "error": "服务器内部错误",
            "detail": str(exc) if os.getenv("DEBUG") else "请联系管理员"
        }
    )


# 静态文件服务 (用于生产环境/start.ps1启动)
from fastapi.staticfiles import StaticFiles
import os

# 构建产物路径
build_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "apps", "mygril_flutter", "build", "web")

if os.path.exists(build_dir):
    app.mount("/app", StaticFiles(directory=build_dir, html=True), name="app")
    print(f"✅ 已挂载静态文件: {build_dir}")
else:
    print(f"⚠️ 未找到构建产物，跳过静态文件挂载: {build_dir}")


# 运行服务（用于开发）
if __name__ == "__main__":
    import uvicorn
    
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    
    uvicorn.run(
        "main:app",
        host=host,
        port=port,
        reload=True  # 开发模式自动重载
    )
