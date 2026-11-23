@echo off
setlocal
rem 给别人用时双击这个：起网关 + 开临时公网隧道 + 把接入信息复制到剪贴板
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0share.ps1" %*
pause
