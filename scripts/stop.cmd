@echo off
setlocal enabledelayedexpansion
rem Kill whatever listens on the gateway port (default 8787, or first argument).
set "PORT=%~1"
if "%PORT%"=="" set "PORT=8787"

set "FOUND="
for /f "tokens=5" %%A in ('netstat -ano ^| findstr LISTENING ^| findstr ":!PORT! "') do (
  set "FOUND=1"
  echo [stop] killing PID %%A on port !PORT!
  taskkill /PID %%A /F >nul 2>nul
)

if not defined FOUND echo [stop] nothing listening on port !PORT!
exit /b 0
