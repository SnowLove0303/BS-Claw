@echo off
if /I not "%~1"=="Claw" (
  echo Usage: BS Claw
  exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-BSClaw.ps1"
exit /b %ERRORLEVEL%
