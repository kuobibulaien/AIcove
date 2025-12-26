#!/bin/bash
# MyGril Cloud 一键部署脚本
# 使用方法：chmod +x deploy.sh && ./deploy.sh

echo "=========================================="
echo "  MyGril Cloud 一键部署脚本"
echo "  服务器IP: 152.136.174.211"
echo "=========================================="
echo ""

# 1. 检查Docker
echo "🔍 检查Docker环境..."
if ! command -v docker &> /dev/null; then
    echo "❌ 未安装Docker，正在安装..."
    curl -fsSL https://get.docker.com | sh
    systemctl start docker
    systemctl enable docker
    echo "✅ Docker安装完成"
else
    echo "✅ Docker已安装"
fi

if ! command -v docker-compose &> /dev/null; then
    echo "❌ 未安装Docker Compose，正在安装..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    echo "✅ Docker Compose安装完成"
else
    echo "✅ Docker Compose已安装"
fi

# 2. 创建配置文件
echo ""
echo "📝 生成配置文件..."
if [ ! -f .env ]; then
    # 生成随机SECRET_KEY
    SECRET_KEY=$(openssl rand -hex 32)
    
    cat > .env << EOF
# MyGril Cloud 配置文件
# 自动生成于 $(date)

# 安全密钥（已自动生成）
SECRET_KEY=${SECRET_KEY}

# 数据库配置（默认SQLite）
DATABASE_URL=sqlite:///./data/sync.db

# CORS配置（允许所有来源，生产环境建议限制）
ALLOWED_ORIGINS=*

# Token过期时间（分钟，默认7天）
ACCESS_TOKEN_EXPIRE_MINUTES=10080

# 服务器配置
HOST=0.0.0.0
PORT=8000
EOF
    echo "✅ 配置文件已生成：.env"
else
    echo "⚠️  配置文件已存在，跳过生成"
fi

# 3. 创建数据目录
echo ""
echo "📁 创建数据目录..."
mkdir -p data
chmod 755 data
echo "✅ 数据目录已创建"

# 4. 停止旧容器（如果存在）
echo ""
echo "🛑 停止旧容器..."
docker-compose down 2>/dev/null || true

# 5. 启动服务
echo ""
echo "🚀 启动服务..."
docker-compose up -d --build

# 6. 等待服务启动
echo ""
echo "⏳ 等待服务启动..."
sleep 5

# 7. 检查状态
echo ""
echo "🔍 检查服务状态..."
if docker ps | grep -q mygril-sync; then
    echo "✅ 容器运行中"
else
    echo "❌ 容器未运行，查看日志："
    docker-compose logs
    exit 1
fi

# 8. 健康检查
echo ""
echo "🏥 健康检查..."
if curl -s http://localhost:8000/health | grep -q "ok"; then
    echo "✅ 服务健康检查通过"
else
    echo "⚠️  健康检查失败，查看日志："
    docker-compose logs --tail 20
fi

# 9. 显示访问信息
echo ""
echo "=========================================="
echo "  ✨ 部署成功！"
echo "=========================================="
echo ""
echo "📡 API地址："
echo "   - 本地访问: http://localhost:8000"
echo "   - 外网访问: http://152.136.174.211:8000"
echo "   - API文档: http://152.136.174.211:8000/docs"
echo ""
echo "🔐 下一步："
echo "   1. 访问 http://152.136.174.211:8000 确认服务运行"
echo "   2. 查看API文档: http://152.136.174.211:8000/docs"
echo "   3. 在Flutter中配置API地址为: http://152.136.174.211:8000"
echo ""
echo "📋 常用命令："
echo "   查看日志: docker-compose logs -f"
echo "   重启服务: docker-compose restart"
echo "   停止服务: docker-compose down"
echo "   更新代码: git pull && docker-compose up -d --build"
echo ""
echo "=========================================="
