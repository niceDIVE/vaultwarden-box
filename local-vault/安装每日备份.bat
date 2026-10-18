@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-backup.ps1"
if errorlevel 1 exit /b 1
exit /b 0
