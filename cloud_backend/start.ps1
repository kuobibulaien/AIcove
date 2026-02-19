# AIcove Cloud Sync - Windows启动脚本

Write-Host "🚀 启动 AIcove 云同步服务..." -ForegroundColor Green

# 检查.env文件
if (-not (Test-Path ".env")) {
    Write-Host "⚠️  未找到.env文件，复制.env.example..." -ForegroundColor Yellow
    Copy-Item ".env.example" ".env"
    Write-Host "❗ 请编辑.env文件，设置SECRET_KEY等配置！" -ForegroundColor Red
    exit 1
}

# 创建数据目录
if (-not (Test-Path "data")) {
    New-Item -ItemType Directory -Path "data" | Out-Null
}

# 激活虚拟环境（如果存在）
if (Test-Path "venv\Scripts\Activate.ps1") {
    & .\venv\Scripts\Activate.ps1
}

# 加载环境变量
Get-Content .env | ForEach-Object {
    if ($_ -notmatch '^#' -and $_ -match '=') {
        $parts = $_ -split '=', 2
        [Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim())
    }
}

# 启动服务
Write-Host "✨ 启动FastAPI服务..." -ForegroundColor Green
$host = $env:HOST
if (-not $host) { $host = "0.0.0.0" }
$port = $env:PORT
if (-not $port) { $port = "8000" }

python -m uvicorn main:app --host $host --port $port --reload
