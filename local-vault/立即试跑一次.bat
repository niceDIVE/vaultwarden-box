@echo off
cd /d "%~dp0"
set "INSTALLED=%LOCALAPPDATA%\kdbx-backup\kdbx-backup.ps1"
if exist "%INSTALLED%" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%INSTALLED%"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0kdbx-backup.ps1"
)
echo.
echo --------------------------------------------
pause
