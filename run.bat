@echo off
REM Double-clickable launcher. Runs run.ps1 without changing system policy (no admin).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1"
echo.
pause
