@echo off
setlocal
rem Close the public tunnel; the local gateway keeps running.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force; Remove-Item '%~dp0..\current-url.txt' -Force -ErrorAction SilentlyContinue; Write-Host '[unshare] tunnel stopped, public URL is gone'"
