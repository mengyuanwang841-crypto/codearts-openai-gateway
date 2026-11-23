# setup-vendor.ps1
#
# Copies the locally installed dsh-codearts plugin bundle into vendor/, then links the
# four @deepseek-ai packages it imports at runtime from your DSH installation.
#
# Why: the gateway reuses the plugin's signing / token refresh / account rotation instead
# of re-implementing them, so it needs the plugin's lib/ to be importable together with
# @deepseek-ai/schemastery, dsh-llm, dsh-llm-pi-ai and dsh-settings.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup-vendor.ps1
#   powershell ... -File scripts/setup-vendor.ps1 -DshNodeModules "F:\dsh\resources\app\dsh\node_modules\@deepseek-ai"
#   powershell ... -File scripts/setup-vendor.ps1 -PluginDir "C:\Users\me\.dsh\profiles\web\node_modules\dsh-codearts"

[CmdletBinding()]
param(
  [string]$DshNodeModules,
  [string]$PluginDir,
  [string]$Target
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$vendorRoot = if ($Target) { $Target } else { Join-Path $root 'vendor\dsh-codearts' }
$packages = @('schemastery', 'dsh-llm', 'dsh-llm-pi-ai', 'dsh-settings')

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
  throw 'node not found. Install Node.js 20+ or add it to PATH.'
}

function Find-PluginDir {
  param([string]$explicit)
  if ($explicit) {
    if (-not (Test-Path (Join-Path $explicit 'lib\index.mjs'))) {
      throw "PluginDir '$explicit' has no lib/index.mjs"
    }
    return $explicit
  }
  $profilesRoot = Join-Path $HOME '.dsh\profiles'
  if (Test-Path $profilesRoot) {
    foreach ($profile in Get-ChildItem $profilesRoot -Directory) {
      $candidate = Join-Path $profile.FullName 'node_modules\dsh-codearts'
      if (Test-Path (Join-Path $candidate 'lib\index.mjs')) { return $candidate }
    }
  }
  throw "dsh-codearts not found under $profilesRoot. Install the plugin in DSH first, or pass -PluginDir."
}

function Find-DshNodeModules {
  param([string]$explicit)
  if ($explicit) {
    if (-not (Test-Path (Join-Path $explicit 'schemastery'))) {
      throw "DshNodeModules '$explicit' has no schemastery subdirectory"
    }
    return $explicit
  }
  $roots = @(
    $env:ProgramFiles,
    ${env:ProgramFiles(x86)},
    (Join-Path $env:LOCALAPPDATA 'Programs'),
    'F:\',
    'D:\',
    'E:\'
  ) | Where-Object { $_ -and (Test-Path $_) }

  foreach ($base in $roots) {
    foreach ($rel in @('dsh\resources\app\dsh\node_modules\@deepseek-ai', 'resources\app\dsh\node_modules\@deepseek-ai')) {
      $candidate = Join-Path $base $rel
      if (Test-Path (Join-Path $candidate 'schemastery')) { return $candidate }
    }
    # one level down: <base>\<vendor>\dsh\resources\...
    foreach ($child in Get-ChildItem $base -Directory -ErrorAction SilentlyContinue) {
      $candidate = Join-Path $child.FullName 'dsh\resources\app\dsh\node_modules\@deepseek-ai'
      if (Test-Path (Join-Path $candidate 'schemastery')) { return $candidate }
    }
  }
  throw "Could not locate the DSH installation. Pass -DshNodeModules <path to ...\dsh\node_modules\@deepseek-ai>."
}

Write-Host "[1/4] locate plugin"
$plugin = Find-PluginDir -explicit $PluginDir
Write-Host "      plugin: $plugin"

Write-Host "[2/4] locate DSH @deepseek-ai packages"
$dshModules = Find-DshNodeModules -explicit $DshNodeModules
Write-Host "      modules: $dshModules"

Write-Host "[3/4] copy bundle to $vendorRoot"
if (Test-Path (Join-Path $vendorRoot 'lib')) { Remove-Item (Join-Path $vendorRoot 'lib') -Recurse -Force }
New-Item -ItemType Directory -Force -Path $vendorRoot | Out-Null
Copy-Item (Join-Path $plugin 'lib') -Destination (Join-Path $vendorRoot 'lib') -Recurse -Force
Copy-Item (Join-Path $plugin 'package.json') -Destination (Join-Path $vendorRoot 'package.json') -Force

Write-Host "[4/4] link runtime dependencies"
$linkRoot = Join-Path $vendorRoot 'node_modules\@deepseek-ai'
New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
foreach ($pkg in $packages) {
  $source = Join-Path $dshModules $pkg
  if (-not (Test-Path $source)) { throw "missing $pkg in $dshModules" }
  $link = Join-Path $linkRoot $pkg
  if (Test-Path $link) { Remove-Item $link -Recurse -Force }
  try {
    New-Item -ItemType Junction -Path $link -Target $source | Out-Null
    Write-Host "      junction $pkg"
  } catch {
    Copy-Item $source -Destination $link -Recurse -Force
    Write-Host "      copied   $pkg (junction unavailable)"
  }
}

$probe = @"
import { pathToFileURL } from 'node:url'
const mod = await import(pathToFileURL(String.raw``$vendorRoot\lib\index.mjs``).href)
const required = ['CodeArtsAccountStore','CodeArtsCatalog','createCodeArtsShim','refreshCatalog','codeartsAccountsPath','codeartsAuthPath']
const missing = required.filter((n) => mod[n] === undefined)
if (missing.length > 0) { console.error('missing exports: ' + missing.join(', ')); process.exit(1) }
console.log('      bundle OK, exports resolved')
"@
$probePath = Join-Path $vendorRoot '.probe.mjs'
Set-Content -Path $probePath -Value $probe -Encoding UTF8
try {
  $nodeExe = Resolve-Node
  & $nodeExe $probePath
  if ($LASTEXITCODE -ne 0) { throw 'bundle probe failed' }
} finally {
  Remove-Item $probePath -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "done. next:"
Write-Host "  node src/gateway.mjs        (or Windows: scripts\start.cmd)"
