@echo off
REM Double-click: quet board Trello -> tao/cap nhat knowledge.md (cach viet title + tags).
cd /d "%~dp0"
set "PATH=%USERPROFILE%\.local\bin;%PATH%"
if not exist ".venv\Scripts\python.exe" (
  echo Chua co moi truong Python. Chay run.bat mot lan truoc.
  pause
  exit /b 1
)
".venv\Scripts\python.exe" build_knowledge.py %*
echo.
pause
