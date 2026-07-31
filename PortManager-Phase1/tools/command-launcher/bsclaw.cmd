@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-BSClaw.ps1"
exit /b %ERRORLEVEL%
