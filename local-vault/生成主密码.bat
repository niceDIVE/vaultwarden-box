@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gen-passphrase.ps1"
if errorlevel 1 exit /b 1
exit /b 0
