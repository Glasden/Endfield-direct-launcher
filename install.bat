@echo off
chcp 65001 >nul
setlocal
rem Double-click to install (default: UAC mode). Pass -Mode Task for the no-UAC variant.
set "PS1=%~dp0install.ps1"
if not exist "%PS1%" (
  echo [x] install.ps1 not found next to this .bat
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%
