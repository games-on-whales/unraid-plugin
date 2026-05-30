# Serve the unraid-plugin repo over HTTP for Unraid plugin install.
# Run from unraid-dev/ after prepare.ps1.

$ErrorActionPreference = "Stop"
$DevDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $DevDir
$EnvFile = Join-Path $DevDir ".env"

$DevPort = 8888
if (Test-Path $EnvFile) {
  Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*DEV_PORT=(\d+)') { $DevPort = [int]$matches[1] }
    if ($_ -match '^\s*DEV_IP=(.+)$') { $script:DevIp = $matches[1].Trim() }
  }
}

if (-not (Test-Path (Join-Path $RepoRoot "gow-dev.plg"))) {
  Write-Host "gow-dev.plg missing - run .\prepare.ps1 first" -ForegroundColor Red
  exit 1
}

if (-not (Test-Path (Join-Path $RepoRoot "dist/settings-ui.txz"))) {
  Write-Host "WARN: dist/settings-ui.txz missing - plugin UI install will fail until you build it." -ForegroundColor Yellow
}

Set-Location $RepoRoot
Write-Host "Serving $RepoRoot on port $DevPort"
if ($DevIp) {
  Write-Host "Unraid: plugin install http://${DevIp}:${DevPort}/gow-dev.plg"
}
Write-Host "Press Ctrl+C to stop."
Write-Host ""

if (Get-Command python -ErrorAction SilentlyContinue) {
  python -m http.server $DevPort
} elseif (Get-Command python3 -ErrorAction SilentlyContinue) {
  python3 -m http.server $DevPort
} else {
  throw "Python not found - install Python or use: npx http-server -p $DevPort"
}
