@echo off
setlocal

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-polish.ps1" %*
