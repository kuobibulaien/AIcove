@echo off
setlocal

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-report-finalize.ps1" %*
