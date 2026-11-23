@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0.."

if not exist "vendor\dsh-codearts\lib\index.mjs" (
  echo [start] vendor bundle missing. Run: npm run setup
  exit /b 1
)

rem node: PATH first, then the runtime bundled with DSH
set "NODE=node"
where node >nul 2>nul
if errorlevel 1 (
  set "NODE="
  for %%P in (
    "F:\dsh\resources\app\runtime\primary-runtime\dependencies\node\bin\node.exe"
    "C:\Program Files\dsh\resources\app\runtime\primary-runtime\dependencies\node\bin\node.exe"
    "%LOCALAPPDATA%\Programs\dsh\resources\app\runtime\primary-runtime\dependencies\node\bin\node.exe"
  ) do (
    if not defined NODE if exist %%P set "NODE=%%~P"
  )
)
if not defined NODE (
  echo [start] node not found. Install Node.js 20+ or set PATH.
  exit /b 1
)

echo [start] node = !NODE!
"!NODE!" "src\gateway.mjs" %*
exit /b %ERRORLEVEL%
