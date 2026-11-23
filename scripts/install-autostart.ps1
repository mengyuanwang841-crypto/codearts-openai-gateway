# install-autostart.ps1 — make the gateway (and optionally the tunnel) start at logon.
#
# Two mechanisms, tried in order:
#   1. Scheduled task (schtasks, "at log on")   — needs no admin normally, cleanest
#   2. Startup folder + hidden VBS launcher     — always works, no privileges needed
#
# Runs at logon rather than at boot: the CodeArts credentials live in
# %USERPROFILE%\.dsh\.codearts-accounts.json and SYSTEM cannot read them.
#
# Usage:
#   powershell -File scripts\install-autostart.ps1
#   powershell -File scripts\install-autostart.ps1 -NoTunnel
#   powershell -File scripts\install-autostart.ps1 -Method Startup

[CmdletBinding()]
param(
  [switch]$NoTunnel,
  [ValidateSet('Auto', 'Task', 'Startup')][string]$Method = 'Auto',
  [string]$TaskName = 'CodeArts Gateway'
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$boot = Join-Path $root 'scripts\boot.ps1'
if (-not (Test-Path $boot)) { throw "boot.ps1 not found: $boot" }

$argLine = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $boot
if (-not $NoTunnel) { $argLine += ' -WithTunnel' }

$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$vbsPath = Join-Path $startupDir 'CodeArts-Gateway.vbs'

function Install-StartupLauncher {
  New-Item -ItemType Directory -Force -Path $startupDir | Out-Null
  $psArgs = $argLine -replace '"', '""'
  $vbs = @"
' CodeArts OpenAI Gateway — logon launcher (hidden window)
Set shell = CreateObject("WScript.Shell")
shell.Run "powershell.exe $psArgs", 0, False
"@
  Set-Content -Path $vbsPath -Value $vbs -Encoding ASCII
  Write-Host "[autostart] installed startup launcher: $vbsPath"
}

function Test-TaskInstalled {
  & schtasks.exe /query /tn $TaskName >$null 2>&1
  return ($LASTEXITCODE -eq 0)
}

$pwshExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if ($Method -ne 'Startup') {
  Write-Host "[autostart] trying scheduled task '$TaskName'"
  & schtasks.exe /create /tn $TaskName /tr "`"$pwshExe`" $argLine" /sc onlogon /f 2>&1 |
    ForEach-Object { Write-Host "  $_" }
  if (Test-TaskInstalled) {
    Write-Host "[autostart] scheduled task created."
    Write-Host "[autostart] verify: schtasks /query /tn `"$TaskName`" /v /fo LIST"
    exit 0
  }
  if ($Method -eq 'Task') {
    Write-Host '[autostart] task creation failed and -Method Task was forced; aborting.'
    exit 1
  }
  Write-Host '[autostart] task creation denied -> falling back to the Startup folder'
}

Install-StartupLauncher
Write-Host ''
Write-Host '[autostart] check it:'
Write-Host "  Get-Content `"$vbsPath`""
Write-Host "  powershell -File scripts\boot.ps1 -WithTunnel   # what it will run"
Write-Host '  remove with: powershell -File scripts\uninstall-autostart.ps1'
exit 0
