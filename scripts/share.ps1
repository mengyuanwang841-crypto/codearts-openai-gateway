# share.ps1 — open a temporary public URL for someone else, and copy the client details.
#
# The URL is a Cloudflare quick tunnel, so it changes every time. That is fine here:
# share -> paste -> they use it -> unshare. Nothing is exposed while the tunnel is down.
#
#   powershell -File scripts\share.ps1
#   powershell -File scripts\share.ps1 -Model GLM-5.2

[CmdletBinding()]
param(
  [string]$Model = 'glm-5.3-flash'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$urlFile = Join-Path $root 'current-url.txt'
$keyFile = Join-Path $root '.gateway-key'

# 1. gateway must be up (boot.ps1 is idempotent)
$up = $false
try {
  $probe = New-Object System.Net.Sockets.TcpClient
  $probe.Connect('127.0.0.1', 8787)
  $up = $true
  $probe.Close()
} catch { }

if (-not $up) {
  Write-Host '[share] gateway is down, starting it'
  & (Join-Path $PSScriptRoot 'boot.ps1') | Out-Null
  Start-Sleep -Seconds 3
}

# 2. tunnel
& (Join-Path $PSScriptRoot 'tunnel.ps1') | ForEach-Object { Write-Host $_ }
if (-not (Test-Path $urlFile)) {
  Write-Host '[share] no tunnel URL; aborting'
  exit 1
}
$url = (Get-Content $urlFile -Raw).Trim()
$key = (Get-Content $keyFile -Raw).Trim()

$text = @"
Base URL : $url/v1
API Key  : $key
Model    : $Model

curl:
  curl $url/v1/chat/completions -H "Authorization: Bearer $key" -H "Content-Type: application/json" -d '{"model":"$Model","messages":[{"role":"user","content":"hi"}],"max_tokens":800}'
"@

$text | Set-Clipboard
Write-Host ''
Write-Host '================ 发给对方的内容（已复制到剪贴板）================'
Write-Host $text
Write-Host '================================================================'
Write-Host ''
Write-Host '[share] when they are done:  scripts\unshare.cmd'
