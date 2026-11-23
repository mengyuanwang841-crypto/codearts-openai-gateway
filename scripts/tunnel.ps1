# tunnel.ps1 — start a Cloudflare quick tunnel to the local gateway and record its URL.
#
# Quick tunnels get a NEW hostname on every start. current-url.txt is rewritten each time,
# so read that file (or the log) for the address in use.
#
# For a hostname that never changes, use scripts/setup-named-tunnel.ps1 instead.

[CmdletBinding()]
param(
  [string]$Target = 'http://127.0.0.1:8787',
  [int]$WaitSeconds = 60
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$tools = Join-Path $root 'tools'
$exe = Join-Path $tools 'cloudflared.exe'
$log = Join-Path $tools 'cloudflared.log'
$urlFile = Join-Path $root 'current-url.txt'

if (-not (Test-Path $exe)) {
  Write-Host "[tunnel] cloudflared.exe not found: $exe"
  exit 1
}

# already running? just report
$running = Get-Process cloudflared -ErrorAction SilentlyContinue
if ($running) {
  $known = if (Test-Path $urlFile) { (Get-Content $urlFile -Raw).Trim() } else { '' }
  Write-Host "[tunnel] already running (PID $($running.Id -join ',')) url=$known"
  exit 0
}

if (Test-Path $log) { Remove-Item $log -Force -ErrorAction SilentlyContinue }

# --protocol http2: QUIC/UDP is unreliable on many CN networks, TCP is not
$line = '"{0}" tunnel --url {1} --no-autoupdate --protocol http2 --logfile "{2}"' -f $exe, $Target, $log
$created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $line }
if ($created.ReturnValue -ne 0) {
  Write-Host "[tunnel] CreateProcess failed rc=$($created.ReturnValue)"
  exit 1
}
Write-Host "[tunnel] cloudflared pid=$($created.ProcessId)"

$url = ''
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 1500
  if (Test-Path $log) {
    $match = Select-String -Path $log -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($match) { $url = $match.Matches[0].Value; break }
  }
}

if ($url -eq '') {
  Write-Host "[tunnel] no URL yet — check $log"
  exit 2
}

Set-Content -Path $urlFile -Value $url -Encoding ASCII
Write-Host "[tunnel] url: $url"
Write-Host "[tunnel] saved to: $urlFile"
exit 0
