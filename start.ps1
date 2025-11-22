# MyGril Project Startup Script (PowerShell)
# Encoding: UTF-8 with BOM

[CmdletBinding()]
param(
    [switch]$Rebuild,
    [switch]$Clean,
    [switch]$SkipFlutter,
    [int]$Port = 8000
)

$ErrorActionPreference = "Stop"
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
try { chcp 65001 > $null } catch {}
function Write-Info { param([string]$msg) Write-Host $msg -ForegroundColor Cyan }
function Write-OK { param([string]$msg) Write-Host $msg -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host $msg -ForegroundColor Yellow }
function Write-Err { param([string]$msg) Write-Host $msg -ForegroundColor Red }

function Write-Banner {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "    MyGril Project Startup" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
}
# Configure Flutter mirrors for China (optional, set USE_CHINA_MIRROR=1 to enable)
# if ($env:USE_CHINA_MIRROR -eq "1") {
#     Write-Info "[Config] Using China mirror for Flutter"
#     $env:PUB_HOSTED_URL = "https://pub.flutter-io.cn"
#     $env:FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn"
#     # Bypass the trust confirmation prompt
#     $env:FLUTTER_STORAGE_BASE_URL_CHINESE_PREFERRED = "true"
# }

$ROOT_DIR = $PSScriptRoot
$BACKEND_DIR = Join-Path $ROOT_DIR "cloud_backend"
$BACKEND_VENV = Join-Path $BACKEND_DIR ".venv"
$BACKEND_PYTHON = Join-Path $BACKEND_VENV "Scripts\python.exe"
$BACKEND_PIP = Join-Path $BACKEND_VENV "Scripts\pip.exe"
$FLUTTER_APP_DIR = Join-Path $ROOT_DIR "apps\mygril_flutter"
$FLUTTER_BUILD_DIR = Join-Path $FLUTTER_APP_DIR "build\web"

$FLUTTER_PATHS = @(
    "$env:FLUTTER_HOME\bin",
    "$env:USERPROFILE\flutter\bin",
    "C:\src\flutter\bin",
    "C:\Flutter\bin"
)
function Find-FreePort {
    param([int]$StartPort = 8000)
    for ($p = $StartPort; $p -le ($StartPort + 20); $p++) {
        try {
            $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $p)
            $listener.Start()
            $listener.Stop()
            return $p
        }
        catch {
            continue
        }
    }
    return $StartPort
}

function Find-Flutter {
    if (Get-Command flutter -ErrorAction SilentlyContinue) {
        return $true
    }

    foreach ($path in $FLUTTER_PATHS) {
        if (Test-Path $path) {
            $flutterExe = Join-Path $path "flutter.bat"
            if (Test-Path $flutterExe) {
                $env:PATH = "$path;$env:PATH"
                Write-OK "[OK] Flutter found: $path"
                return $true
            }
        }
    }
    return $false
}

function Test-NeedRebuild {
    param(
        [string]$ExpectedApiBaseUrl = $null
    )

    if ($Rebuild -or $env:FORCE_REBUILD -eq "1") {
        Write-Warn "[Check] Force rebuild mode"
        return $true
    }

    $indexHtml = Join-Path $FLUTTER_BUILD_DIR "index.html"
    if (-not (Test-Path $indexHtml)) {
        Write-Warn "[Check] Build output missing (index.html)"
        return $true
    }

    try {
        $indexContent = Get-Content $indexHtml -Raw -ErrorAction SilentlyContinue
        if ($indexContent -match '<base href="/">') {
            Write-Warn "[Check] Wrong base href (expected /app/)"
            return $true
        }
    }
    catch {
        Write-Warn "[Check] Failed to read index.html"
        return $true
    }

    # Check for Flutter build artifacts (compatible with Flutter 3.x+)
    $buildFiles = @("flutter.js", "main.dart.js", "main.dart.mjs")
    $foundArtifact = $false
    $artifactFile = $null

    foreach ($file in $buildFiles) {
        $filePath = Join-Path $FLUTTER_BUILD_DIR $file
        if (Test-Path $filePath) {
            $foundArtifact = $true
            $artifactFile = $filePath
            break
        }
    }

    if (-not $foundArtifact) {
        Write-Warn "[Check] No Flutter build artifacts found"
        return $true
    }

    # Check if source code is newer than build
    try {
        $srcDirs = @(
            (Join-Path $FLUTTER_APP_DIR "lib"),
            (Join-Path $FLUTTER_APP_DIR "pubspec.yaml")
        )

        $buildTime = (Get-Item $artifactFile).LastWriteTime
        foreach ($srcPath in $srcDirs) {
            if (Test-Path $srcPath) {
                $srcTime = if ((Get-Item $srcPath).PSIsContainer) {
                    (Get-ChildItem $srcPath -Recurse -File -ErrorAction SilentlyContinue |
                    Measure-Object -Property LastWriteTime -Maximum -ErrorAction SilentlyContinue).Maximum
                }
                else {
                    (Get-Item $srcPath).LastWriteTime
                }

                if ($srcTime -and $srcTime -gt $buildTime) {
                    Write-Warn "[Check] Source code updated since last build"
                    return $true
                }
            }
        }
    }
    catch {
        Write-Warn "[Check] Failed to compare timestamps: $_"
        # Don't fail, just skip rebuild check
    }

    # Ensure API_BASE_URL in built bundle matches expected backend port when provided
    if ($ExpectedApiBaseUrl) {
        try {
            $candidates = @(
                (Join-Path $FLUTTER_BUILD_DIR "main.dart.js"),
                (Join-Path $FLUTTER_BUILD_DIR "main.dart.mjs")
            )
            foreach ($cand in $candidates) {
                if (Test-Path $cand) {
                    $raw = Get-Content $cand -Raw -ErrorAction SilentlyContinue
                    if ($raw) {
                        # If bundle contains hard-coded localhost with port and it's not the expected one, trigger rebuild
                        if ($raw -match 'http://localhost:\d+') {
                            if ($raw -notmatch [Regex]::Escape($ExpectedApiBaseUrl)) {
                                Write-Warn "[Check] API_BASE_URL mismatch in build (expected $ExpectedApiBaseUrl)"
                                return $true
                            }
                        }
                    }
                }
            }
        }
        catch {
            Write-Warn "[Check] Failed to verify API_BASE_URL in bundle: $_"
        }
    }

    Write-OK "[Check] No rebuild needed"
    return $false
}

function Invoke-ProcessWithTimeout {
    param($FilePath, $Arguments, $TimeoutSec, $Env)
    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $FilePath
    $pinfo.Arguments = $Arguments
    $pinfo.RedirectStandardOutput = $false
    $pinfo.RedirectStandardError = $false
    $pinfo.UseShellExecute = $false
    if ($Env) {
        foreach ($k in $Env.Keys) { $pinfo.EnvironmentVariables[$k] = $Env[$k] }
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $pinfo
    $p.Start() | Out-Null
    if ($p.WaitForExit($TimeoutSec * 1000)) {
        return [PSCustomObject]@{ Success = ($p.ExitCode -eq 0); ExitCode = $p.ExitCode; TimedOut = $false }
    }
    else {
        try { $p.Kill() } catch {}
        return [PSCustomObject]@{ Success = $false; ExitCode = -1; TimedOut = $true }
    }
}

function Run-FlutterPubGet {
    param([int]$TimeoutSec)
    
    # 1. Default
    Write-Info "[pub] Trying default mirror..."
    $r1 = Invoke-ProcessWithTimeout -FilePath "flutter.bat" -Arguments "pub get" -TimeoutSec $TimeoutSec
    if ($r1.Success) { return [PSCustomObject]@{ Success = $true; AppliedMirror = "default"; Env = $null } }
    if ($r1.TimedOut) { Write-Warn "[pub] default timed out" }
    
    # 2. Tuna
    $tunaEnv = @{ PUB_HOSTED_URL = "https://mirrors.tuna.tsinghua.edu.cn/dart-pub"; FLUTTER_STORAGE_BASE_URL = "https://mirrors.tuna.tsinghua.edu.cn/flutter" }
    Write-Info "[pub] Trying TUNA mirror..."
    $r2 = Invoke-ProcessWithTimeout -FilePath "flutter.bat" -Arguments "pub get" -TimeoutSec $TimeoutSec -Env $tunaEnv
    if ($r2.Success) { return [PSCustomObject]@{ Success = $true; AppliedMirror = "tuna"; Env = $tunaEnv } }

    # 3. Legacy
    $legacyEnv = @{ PUB_HOSTED_URL = "https://pub.flutter-io.cn"; FLUTTER_STORAGE_BASE_URL = "https://storage.flutter-io.cn" }
    Write-Info "[pub] Trying legacy mirror..."
    $r3 = Invoke-ProcessWithTimeout -FilePath "flutter.bat" -Arguments "pub get" -TimeoutSec $TimeoutSec -Env $legacyEnv
    if ($r3.Success) { return [PSCustomObject]@{ Success = $true; AppliedMirror = "legacy"; Env = $legacyEnv } }

    return [PSCustomObject]@{ Success = $false; AppliedMirror = $null; Env = $null }
}

function Build-Flutter {
    param(
        [string]$ApiBaseUrl = $null
    )
    Write-Info "[Build] Building Flutter web..."

    if (-not (Find-Flutter)) {
        Write-Err "[ERROR] Flutter SDK not found"
        Write-Warn "Download: https://flutter.dev/docs/get-started/install/windows"
        throw "Flutter not installed"
    }

    Push-Location $FLUTTER_APP_DIR
    try {
        if ($Clean) {
            Write-Info "[Build] Cleaning build cache (flutter clean)..."
            & flutter clean
            if ($LASTEXITCODE -ne 0) { Write-Warn "[Build] flutter clean failed, continuing..." }
        }

        if (Test-Path $FLUTTER_BUILD_DIR) {
            Write-Info "[Build] Cleaning old build output..."
            Remove-Item $FLUTTER_BUILD_DIR -Recurse -Force -ErrorAction SilentlyContinue
        }

        Write-Info "[Flutter] Getting dependencies..."
        $pubGetResult = Run-FlutterPubGet -TimeoutSec 180
        if (-not $pubGetResult.Success) {
            Write-Warn "[Flutter] pub get failed, will try to continue build..."
        }
        elseif ($pubGetResult.AppliedMirror -ne "default") {
            Write-Info "[Flutter] Using mirror: $($pubGetResult.AppliedMirror)"
            if ($pubGetResult.Env) {
                foreach ($k in $pubGetResult.Env.Keys) { Set-Item -Path Env:$k -Value $pubGetResult.Env[$k] }
            }
        }

        $args = @('build', 'web', '--release', '--base-href', '/app/', '--pwa-strategy', 'none')
        if ($ApiBaseUrl -and $ApiBaseUrl.Trim() -ne '') {
            Write-Info "[Flutter] Inject API_BASE_URL=$ApiBaseUrl"
            $args += "--dart-define=API_BASE_URL=$ApiBaseUrl"
        }
        
        Write-Info "[Flutter] Building web bundle..."
        & flutter @args
        if ($LASTEXITCODE -ne 0) {
            throw "flutter build web failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }
}

function Setup-Backend {
    Write-Info "[Backend] Setting up Python environment..."

    # Check for Python
    $pythonCmd = $null
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $pythonCmd = "python"
    }
    elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
        $pythonCmd = "python3"
    }
    else {
        Write-Err "[ERROR] Python not found in PATH"
        Write-Warn "Download Python: https://www.python.org/downloads/"
        throw "Python not installed"
    }

    # Prefer Python 3.12 for backend (binary wheels for numpy on Windows)
    $pyVersion = try { (& $pythonCmd -c "import sys;print(str(sys.version_info[0])+'.'+str(sys.version_info[1]))").Trim() } catch { "" }
    $hasPyLauncher = Get-Command py -ErrorAction SilentlyContinue

    # If venv exists with 3.13+ and user requested -Rebuild, recreate with 3.12 if available
    if ($Rebuild -and (Test-Path $BACKEND_PYTHON)) {
        $venvVer = try { (& $BACKEND_PYTHON -c "import sys;print(str(sys.version_info[0])+'.'+str(sys.version_info[1]))").Trim() } catch { "" }
        if ($venvVer -ge "3.13" -and $hasPyLauncher) {
            Write-Warn "[Backend] Recreating venv with Python 3.12 for dependency compatibility"
            try { Remove-Item -Recurse -Force $BACKEND_VENV -ErrorAction SilentlyContinue } catch {}
        }
    }

    # Create virtual environment if needed (prefer py -3.12 when available)
    if (-not (Test-Path $BACKEND_VENV)) {
        Write-Info "[Backend] Creating virtual environment..."
        try {
            if ($hasPyLauncher) {
                & py -3.12 -m venv $BACKEND_VENV
            }
            else {
                & $pythonCmd -m venv $BACKEND_VENV
            }
            if ($LASTEXITCODE -ne 0) { throw "Failed to create virtual environment (exit code: $LASTEXITCODE)" }
        }
        catch {
            Write-Err "[Backend] venv creation failed: $_"
            throw
        }
    }

    # Verify virtual environment
    if (-not (Test-Path $BACKEND_PYTHON)) {
        Write-Err "[ERROR] Virtual environment Python not found: $BACKEND_PYTHON"
        Write-Warn "Try deleting backend\.venv folder and run again"
        throw "Virtual environment corrupted"
    }

    # Check and install dependencies
    try {
        $uvicornCheck = & $BACKEND_PYTHON -c "import uvicorn, fastapi, sqlmodel" 2>&1
        $needInstall = $LASTEXITCODE -ne 0
    }
    catch {
        $needInstall = $true
    }

    # If user specifies -Rebuild or explicitly requests force reinstall, force install dependencies
    if ($Rebuild -or $env:FORCE_REINSTALL -eq "1") { $needInstall = $true }

    if ($needInstall) {
        Write-Info "[Backend] Installing dependencies..."

        # Upgrade pip first
        Write-Info "[Backend] Upgrading pip..."
        & $BACKEND_PYTHON -m pip install --upgrade pip 2>&1 | Out-Null

        Push-Location $BACKEND_DIR
        try {
            $reqFile = Join-Path $BACKEND_DIR "requirements.txt"
            if (-not (Test-Path $reqFile)) {
                Write-Err "[ERROR] requirements.txt not found: $reqFile"
                throw "requirements.txt missing"
            }

            Write-Info "[Backend] Installing from requirements.txt..."
            & $BACKEND_PIP install -r requirements.txt
            if ($LASTEXITCODE -ne 0) {
                throw "Dependency installation failed (exit code: $LASTEXITCODE)"
            }
        }
        catch {
            Write-Err "[Backend] Dependency installation failed: $_"
            throw
        }
        finally {
            Pop-Location
        }
    }

    Write-OK "[Backend] Python environment ready"
}

function Start-Server {
    param([int]$ServerPort)

    Write-Info "[Server] Starting on port $ServerPort..."

    # Check .env file
    $envFile = Join-Path $BACKEND_DIR ".env"
    if (-not (Test-Path $envFile)) {
        Write-Host ""
        Write-Warn "========================================"
        Write-Warn "  WARNING: backend\.env not found!"
        Write-Warn "========================================"
        Write-Warn "The server will start, but features requiring API keys"
        Write-Warn "will not work (LLM chat, TTS, etc.)"
        Write-Host ""
        Write-Host "To fix this:" -ForegroundColor Yellow
        Write-Host "  1. Copy backend\.env.example to backend\.env" -ForegroundColor Cyan
        Write-Host "  2. Edit backend\.env and add your API keys" -ForegroundColor Cyan
        Write-Host ""
        Start-Sleep -Seconds 3
    }

    # Set Python path
    $env:PYTHONPATH = $BACKEND_DIR

    Push-Location $BACKEND_DIR
    try {
        # Verify uvicorn is available
        & $BACKEND_PYTHON -c "import uvicorn" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "uvicorn not installed properly"
        }

        # Start server
        & $BACKEND_PYTHON -m uvicorn main:app --host 0.0.0.0 --port $ServerPort --reload
    }
    catch {
        Write-Err "[Server] Failed to start: $_"
        throw
    }
    finally {
        Pop-Location
    }
}

# ==================== Main ====================

try {
    Write-Banner

    # Pick backend port early so we can inject into Flutter build
    $FinalPort = Find-FreePort -StartPort $Port
    if ($FinalPort -ne $Port) {
        Write-Warn "[Notice] Port $Port busy, using $FinalPort instead"
    }

    # Setup backend
    try {
        Setup-Backend
        Write-Host ""
    }
    catch {
        Write-Host ""
        Write-Err "========================================"
        Write-Err "  Backend Setup Failed"
        Write-Err "========================================"
        Write-Host ""
        Write-Host "Error: $_" -ForegroundColor Red
        Write-Host ""
        Write-Host "Troubleshooting:" -ForegroundColor Yellow
        Write-Host "  - Check Python is installed (python --version)" -ForegroundColor Cyan
        Write-Host "  - Try deleting backend\.venv and run again" -ForegroundColor Cyan
        Write-Host "  - Check requirements.txt exists" -ForegroundColor Cyan
        Write-Host ""
        throw
    }

    # Build or check Flutter
    if ($SkipFlutter) {
        Write-Warn "[Frontend] Skipping Flutter build (-SkipFlutter flag set)"
        Write-Host ""
    }
    else {
        try {
            $apiBase = "http://localhost:$FinalPort"
            if (Test-NeedRebuild -ExpectedApiBaseUrl $apiBase) {
                Build-Flutter -ApiBaseUrl $apiBase
                Write-Host ""
            }
            else {
                Write-OK "[Frontend] Using existing build"
                Write-Host ""
            }
        }
        catch {
            Write-Host ""
            Write-Err "========================================"
            Write-Err "  Flutter Build Failed"
            Write-Err "========================================"
            Write-Host ""
            Write-Host "Error: $_" -ForegroundColor Red
            Write-Host ""
            Write-Host "Troubleshooting:" -ForegroundColor Yellow
            Write-Host "  - Check Flutter is installed (flutter --version)" -ForegroundColor Cyan
            Write-Host "  - Run: flutter doctor" -ForegroundColor Cyan
            Write-Host "  - Check apps\mygril_flutter directory exists" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "Note: You can skip Flutter build with:" -ForegroundColor Yellow
            Write-Host "      .\start.ps1 -SkipFlutter" -ForegroundColor Yellow
            Write-Host "      To clean cache and rebuild:" -ForegroundColor Yellow
            Write-Host "      .\start.ps1 -Clean" -ForegroundColor Yellow
            Write-Host ""
            throw
        }
    }

    # Show startup success message
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  🚀 MyGril Service Started!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Backend API:  " -NoNewline
    Write-Host "http://localhost:$FinalPort" -ForegroundColor Cyan
    Write-Host "  Web UI:       " -NoNewline
    Write-Host "http://localhost:$FinalPort/app/#/" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  API Docs:     " -NoNewline
    Write-Host "http://localhost:$FinalPort/docs" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  �'� Tips:" -ForegroundColor Yellow
    Write-Host "     - Press Ctrl+C to stop the server" -ForegroundColor Gray
    Write-Host "     - Logs will appear below" -ForegroundColor Gray
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""

    # Start server
    Start-Server -ServerPort $FinalPort

}
catch {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  ❌ Startup Failed" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error: $_" -ForegroundColor Red
    Write-Host ""

    if ($_.Exception) {
        Write-Host "Details: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
    }

    if ($_.ScriptStackTrace) {
        Write-Host "Stack Trace:" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        Write-Host ""
    }

    Write-Host "For help, check:" -ForegroundColor Yellow
    Write-Host "  - README.md in the project root" -ForegroundColor Cyan
    Write-Host "  - Run with verbose: .\start.ps1 -Verbose" -ForegroundColor Cyan
    Write-Host ""

    exit 1
}
finally {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  Service Stopped" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""
}


