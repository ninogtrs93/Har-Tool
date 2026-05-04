@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Teams-Web-HAR-Capture.ps1"
if not exist "%PS_SCRIPT%" (
  echo Fout: Teams-Web-HAR-Capture.ps1 niet gevonden.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -ConfigPath "%SCRIPT_DIR%config.json"
set "EXITCODE=%ERRORLEVEL%"
echo.
echo Klaar met exitcode %EXITCODE%.
pause
exit /b %EXITCODE%
