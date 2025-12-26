#!/bin/bash
# MyGril Cloud Sync - 启动脚本

echo "🚀 启动 MyGril 云同步服务..."

# 检查.env文件
if [ ! -f .env ]; then
    echo "⚠️  未找到.env文件，复制.env.example..."
    cp .env.example .env
    echo "❗ 请编辑.env文件，设置SECRET_KEY等配置！"
    exit 1
fi

# 创建数据目录
mkdir -p data

# 激活虚拟环境（如果存在）
if [ -d "venv" ]; then
    source venv/bin/activate
fi

# 加载环境变量
export $(cat .env | grep -v '^#' | xargs)

# 启动服务
echo "✨ 启动FastAPI服务..."
uvicorn main:app --host ${HOST:-0.0.0.0} --port ${PORT:-8000} --reload
