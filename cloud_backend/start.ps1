$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
$bindHost = if ($env:HOST) { $env:HOST } else { "127.0.0.1" }
$port = if ($env:PORT) { $env:PORT } else { "8000" }
python -m uvicorn sync_v3.app:app --env-file .env --host $bindHost --port $port
exit $LASTEXITCODE
