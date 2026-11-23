# setup-named-tunnel.ps1 — a Cloudflare tunnel whose hostname never changes.
#
# Quick tunnels (tunnel.ps1) get a random *.trycloudflare.com name on every start.
# A named tunnel bound to your own domain keeps one stable URL across reboots.
#
# Prerequisites:
#   1. a domain on Cloudflare (free plan is fine)
#   2. run once:  tools\cloudflared.exe tunnel login     (opens the browser)
#
# Usage:
#   powershell -File scripts\setup-named-tunnel.ps1 -Hostname api.example.com
#   powershell -File scripts\setup-named-tunnel.ps1 -Hostname api.example.com -Tunnel codearts
#
# After this runs, `cloudflared service install` makes it a Windows service that survives
# reboots. Verify with:  Get-Service cloudflared

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Hostname,
  [string]$Tunnel = 'codearts',
  [string]$Target = 'http://127.0.0.1:8787',
  [switch]$SkipServiceInstall
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'tools\cloudflared.exe'
if (-not (Test-Path $exe)) { throw "cloudflared.exe not found: $exe (run the README setup first)" }

$cfDir = Join-Path $env:USERPROFILE '.cloudflared'
$config = Join-Path $cfDir 'config.yml'

Write-Host '[1/4] tunnel login (browser) — skip if ~/.cloudflared/cert.pem already exists'
if (-not (Test-Path (Join-Path $cfDir 'cert.pem'))) {
  & $exe tunnel login
} else {
  Write-Host '      cert.pem present, skipping'
}

Write-Host "[2/4] create tunnel '$Tunnel'"
$existing = & $exe tunnel list 2>$null | Select-String -Pattern "\b$Tunnel\b"
if (-not $existing) {
  & $exe tunnel create $Tunnel
} else {
  Write-Host '      already exists'
}

Write-Host "[3/4] route dns $Hostname -> $Tunnel"
& $exe tunnel route dns $Tunnel $Hostname

Write-Host "[4/4] write config: $config"
New-Item -ItemType Directory -Force -Path $cfDir | Out-Null
$yaml = @"
tunnel: $Tunnel
credentials-file: $cfDir\$Tunnel.json
ingress:
  - hostname: $Hostname
    service: $Target
    originRequest:
      noTLSVerify: false
      connectTimeout: 30s
  - service: http_status:404
"@
Set-Content -Path $config -Value $yaml -Encoding UTF8

Write-Host ''
Write-Host "done. stable endpoint: https://$Hostname/v1"
Write-Host ''
Write-Host 'run it now      : ' + "& `"$exe`" tunnel run $Tunnel"
if (-not $SkipServiceInstall) {
  Write-Host 'or as a service : ' + "& `"$exe`" --config `"$config`" service install   (elevated shell)"
  Write-Host '                  then: Start-Service cloudflared'
}
Write-Host ''
Write-Host 'note: once the service owns the tunnel, do not also run tunnel.ps1 —'
Write-Host '      two connectors on one tunnel are fine for Cloudflare but confusing to debug.'
