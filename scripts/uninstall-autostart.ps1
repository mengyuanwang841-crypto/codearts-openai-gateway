# uninstall-autostart.ps1 — remove every autostart mechanism this repo installed.

[CmdletBinding()]
param([string]$TaskName = 'CodeArts Gateway')

$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$vbsPath = Join-Path $startupDir 'CodeArts-Gateway.vbs'

if (Test-Path $vbsPath) {
  Remove-Item $vbsPath -Force
  Write-Host "[autostart] removed startup launcher: $vbsPath"
} else {
  Write-Host '[autostart] no startup launcher present'
}

& schtasks.exe /query /tn $TaskName >$null 2>&1
if ($LASTEXITCODE -eq 0) {
  & schtasks.exe /delete /tn $TaskName /f 2>&1 | ForEach-Object { Write-Host "  $_" }
  Write-Host "[autostart] removed scheduled task: $TaskName"
} else {
  Write-Host '[autostart] no scheduled task present'
}

Write-Host ''
Write-Host '[autostart] note: running processes are not stopped. Use scripts\stop.cmd and'
Write-Host '            "Get-Process cloudflared | Stop-Process" if you want them gone too.'
exit 0
