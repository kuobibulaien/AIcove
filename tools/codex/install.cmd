@echo off
setlocal

set "POWERSHELL_EXE="

if not defined POWERSHELL_EXE if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "POWERSHELL_EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined POWERSHELL_EXE if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "POWERSHELL_EXE=%ProgramW6432%\PowerShell\7\pwsh.exe"
if not defined POWERSHELL_EXE if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" set "POWERSHELL_EXE=%ProgramFiles(x86)%\PowerShell\7\pwsh.exe"
if not defined POWERSHELL_EXE if exist "C:\Program Files\PowerShell\7\pwsh.exe" set "POWERSHELL_EXE=C:\Program Files\PowerShell\7\pwsh.exe"
if not defined POWERSHELL_EXE if exist "C:\Program Files (x86)\PowerShell\7\pwsh.exe" set "POWERSHELL_EXE=C:\Program Files (x86)\PowerShell\7\pwsh.exe"
if not defined POWERSHELL_EXE if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined POWERSHELL_EXE if exist "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" set "POWERSHELL_EXE=C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

if not defined POWERSHELL_EXE (
    echo [codex-polish-install] 找不到可用的 PowerShell 可执行文件。 1>&2
    exit /b 1
)

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
