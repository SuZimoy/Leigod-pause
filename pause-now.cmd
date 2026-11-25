@echo off
chcp 65001 >nul
cd /d "%~dp0"
set CORE=C:\ProgramData\LeigodGuard\leigod-pause.ps1
if not exist "%CORE%" set CORE=%~dp0leigod-pause.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File "%CORE%" -Pause
pause
