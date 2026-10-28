@echo off
chcp 65001 >nul
setlocal
rem Launch Endfield directly (single UAC prompt, no official launcher UI).
rem Extra arguments are forwarded to Endfield.exe.
set "HERE=%~dp0"
set "PS1="
if exist "%HERE%Start-Endfield.ps1" set "PS1=%HERE%Start-Endfield.ps1"
if not defined PS1 if exist "%HERE%..\src\Start-Endfield.ps1" set "PS1=%HERE%..\src\Start-Endfield.ps1"
if not defined PS1 if exist "%LOCALAPPDATA%\Programs\EndfieldDirect\Start-Endfield.ps1" set "PS1=%LOCALAPPDATA%\Programs\EndfieldDirect\Start-Endfield.ps1"
if not defined PS1 (
  echo [x] Start-Endfield.ps1 not found. Run install.ps1 first.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -GameArgs "%*"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
