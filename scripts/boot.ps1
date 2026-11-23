# boot.ps1 — start the gateway (and optionally the tunnel) for autostart.
#
# Idempotent: if the port is already listening / cloudflared already running, it does nothing.
# Used by the "CodeArts Gateway" scheduled task (logon trigger).

[CmdletBinding()]
param(
  [switch]$WithTunnel,
  [string]$TunnelTarget = 'http://127.0.0.1:8787'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null

function Resolve-Node {
  $onPath = Get-Command node -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  $candidates = @(
    'F:\dsh\resources\app\runtime\primary-runtime\dependencies\node\bin\node.exe',
    'C:\Program Files\dsh\resources\app\runtime\primary-runtime\dependencies\node\bin\node.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\dsh\resources\app\runtime\primary-runtime\dependencies\node\bin\node.exe')
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) { return $candidate }
  }
  return $null
}

function Quote([string]$value) {
  if ($value -match '\s') { return '"' + $value + '"' }
  return $value
}

# ── gateway ────────────────────────────────────────────────────────
$listening = $false
try {
  $probe = New-Object System.Net.Sockets.TcpClient
  $probe.Connect('127.0.0.1', 8787)
  $listening = $true
  $probe.Close()
} catch { }

if ($listening) {
  Write-Host '[boot] gateway already listening on 8787'
} else {
  $node = Resolve-Node
  if (-not $node) {
    Write-Host '[boot] node not found; cannot start gateway'
    exit 1
  }
  $gatewayLog = Join-Path $logs 'gateway.log'
  $cmd = 'cmd.exe /c {0} {1} >> {2} 2>&1' -f (Quote $node), (Quote (Join-Path $root 'src\gateway.mjs')), (Quote $gatewayLog)
  $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
  if ($created.ReturnValue -ne 0) {
    Write-Host "[boot] failed to start gateway rc=$($created.ReturnValue)"
    exit 1
  }
  Write-Host "[boot] gateway started pid=$($created.ProcessId)"

  # give it a moment so the tunnel does not hit a closed port
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 500
    try {
      $probe = New-Object System.Net.Sockets.TcpClient
      $probe.Connect('127.0.0.1', 8787)
      $probe.Close()
      break
    } catch { }
  }
}

# ── tunnel ─────────────────────────────────────────────────────────
if ($WithTunnel) {
  & (Join-Path $PSScriptRoot 'tunnel.ps1') -Target $TunnelTarget
}

exit 0
