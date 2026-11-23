# rotate-key.ps1 — replace the gateway API key (e.g. after sharing it with someone).
#
# Deletes .gateway-key, restarts the gateway, prints the new key.
# Anyone you shared the old key with loses access immediately.

[CmdletBinding()]
param()

$root = Split-Path -Parent $PSScriptRoot
$keyFile = Join-Path $root '.gateway-key'

Write-Host '[rotate] stopping gateway'
& (Join-Path $PSScriptRoot 'stop.cmd') 2>&1 | ForEach-Object { Write-Host "  $_" }

if (Test-Path $keyFile) { Remove-Item $keyFile -Force }
Start-Sleep -Seconds 2

Write-Host '[rotate] starting gateway'
& (Join-Path $PSScriptRoot 'boot.ps1') | ForEach-Object { Write-Host "  $_" }
Start-Sleep -Seconds 5

if (Test-Path $keyFile) {
  $key = (Get-Content $keyFile -Raw).Trim()
  Write-Host ''
  Write-Host "new API key: $key"
  Write-Host ''
  Write-Host 'clients using the old key now get 401.'
} else {
  Write-Host '[rotate] key file not created; check logs\gateway.log'
  exit 1
}
