# Prepare a local Unraid dev install: checkout draft branch, build settings-ui.txz,
# generate gow-dev.plg, print plugin install commands.
param(
  [switch]$SkipGit,
  [switch]$SkipTxz
)
#   cd unraid-plugin\unraid-dev
#   .\prepare.ps1
#   .\serve.ps1
#
# Optional: copy .env.example to .env and set DEV_IP if auto-detect picks the wrong NIC.

$ErrorActionPreference = "Stop"
$DevDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $DevDir
$EnvFile = Join-Path $DevDir ".env"

function Get-LanIp {
  try {
    $cfg = Get-NetIPConfiguration -ErrorAction SilentlyContinue |
      Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -eq 'Up' } |
      Select-Object -First 1
    if ($cfg -and $cfg.IPv4Address) { return $cfg.IPv4Address.IPAddress.ToString() }
  } catch { }

  $fallback = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' -and $_.PrefixOrigin -ne 'WellKnown' } |
    Select-Object -First 1).IPAddress
  if ($fallback) { return $fallback.ToString() }
  return "127.0.0.1"
}

function Convert-ToWslPath([string]$WindowsPath) {
  if ($WindowsPath -match '^([A-Za-z]):\\(.*)$') {
    $drive = $matches[1].ToLower()
    $rest = ($matches[2] -replace '\\', '/')
    return "/mnt/$drive/$rest"
  }
  return ($WindowsPath -replace '\\', '/')
}

# Load .env
$DevIp = $null
$DevPort = 8888
$PluginBranch = "cursor/config-setup-flow-c2d1"
$SkipGit = $SkipGit.IsPresent
$SkipTxz = $SkipTxz.IsPresent
$BuildWolfDen = $false

if (Test-Path $EnvFile) {
  Get-Content $EnvFile | ForEach-Object {
    if ($_ -match '^\s*([^#=]+)=(.*)$') {
      $k = $matches[1].Trim(); $v = $matches[2].Trim()
      switch ($k) {
        "DEV_IP" { $DevIp = $v }
        "DEV_PORT" { $DevPort = [int]$v }
        "PLUGIN_BRANCH" { $PluginBranch = $v }
        "BUILD_WOLF_DEN" { $BuildWolfDen = ($v -eq "1" -or $v -eq "true") }
      }
    }
  }
}
if (-not $DevIp) { $DevIp = Get-LanIp }

Set-Location $RepoRoot
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " GoW Unraid dev prepare" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " Repo:   $RepoRoot"
Write-Host " Branch: $PluginBranch"
Write-Host " Serve:  http://${DevIp}:${DevPort}/"
Write-Host ""

if (-not $SkipGit) {
  Write-Host "==> Checking out $PluginBranch" -ForegroundColor Yellow
  git fetch origin 2>$null
  git fetch fork 2>$null
  $exists = git rev-parse --verify $PluginBranch 2>$null
  if (-not $exists) {
    git checkout -B $PluginBranch "fork/$($PluginBranch -replace '^draft/','')" 2>$null
    if ($LASTEXITCODE -ne 0) { git checkout -B $PluginBranch "origin/main" }
  } else {
    git checkout $PluginBranch
  }
  if ($LASTEXITCODE -ne 0) { throw "Could not checkout $PluginBranch" }
}

if (-not $SkipTxz) {
  Write-Host "==> Building dist/settings-ui.txz" -ForegroundColor Yellow
  $built = $false

  if (Get-Command wsl -ErrorAction SilentlyContinue) {
    $wslRoot = Convert-ToWslPath $RepoRoot
    wsl bash -lc "sed -i 's/\r$//' '$wslRoot/unraid-dev/build-txz.sh' 2>/dev/null; bash '$wslRoot/unraid-dev/build-txz.sh'"
    if ($LASTEXITCODE -eq 0) { $built = $true }
  }

  if (-not $built -and (Get-Command bash -ErrorAction SilentlyContinue)) {
    Push-Location $RepoRoot
    bash "./unraid-dev/build-txz.sh"
    Pop-Location
    if ($LASTEXITCODE -eq 0) { $built = $true }
  }

  if (-not $built) {
    Write-Host "WARN: Could not build txz (need WSL or Git Bash). UI install will fail until you run:" -ForegroundColor Red
    Write-Host "  wsl bash unraid-dev/build-txz.sh" -ForegroundColor Red
  } elseif (-not (Test-Path "$RepoRoot/dist/settings-ui.txz")) {
    throw "build-txz.sh ran but dist/settings-ui.txz is missing"
  } else {
    $sz = (Get-Item "$RepoRoot/dist/settings-ui.txz").Length
    Write-Host "    dist/settings-ui.txz ($sz bytes)" -ForegroundColor Green
  }
}

Write-Host "==> Generating gow-dev.plg" -ForegroundColor Yellow
& "$DevDir/generate-dev-plg.ps1" -DevIp $DevIp -DevPort $DevPort

# Persist resolved values for serve.ps1
@"
# Auto-written by prepare.ps1 $(Get-Date -Format 'yyyy-MM-dd HH:mm')
DEV_IP=$DevIp
DEV_PORT=$DevPort
PLUGIN_BRANCH=$PluginBranch
"@ | Set-Content -Path $EnvFile -Encoding UTF8

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " Next steps" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
Write-Host " 1. On this PC (keep running):" -ForegroundColor White
Write-Host "      cd $DevDir"
Write-Host "      .\serve.ps1"
Write-Host ""
Write-Host " 2. On Unraid (SSH or terminal):" -ForegroundColor White
Write-Host "      plugin remove gow.plg"
Write-Host "      plugin install http://${DevIp}:${DevPort}/gow-dev.plg"
Write-Host ""
Write-Host " 3. In browser: Settings -> Games on Whales -> GPU + appdata -> Install"
Write-Host ""
Write-Host " 4. After code edits on this PC:" -ForegroundColor White
Write-Host "      .\prepare.ps1 -SkipGit"
Write-Host "    On Unraid (one command - UI + scripts):"
Write-Host "      bash /boot/config/plugins/gow/scripts/dev-sync.sh http://${DevIp}:${DevPort}"
Write-Host ""
Write-Host "    First-time only: plugin install http://${DevIp}:${DevPort}/gow-dev.plg"
Write-Host "    (Re-install only if dev-sync.sh is missing or you changed gow.plg itself.)"
Write-Host ""
Write-Host " Optional - custom Wolf Den (Settings overhaul):" -ForegroundColor DarkGray
Write-Host '   cd ..\wolf-den; git checkout local/test-all'
Write-Host '   docker build -t ghcr.io/<your-org>/wolf-den:local-test .; docker push ...'
Write-Host "   Add to /boot/config/plugins/gow/gow.cfg:"
Write-Host "     WOLF_DEN_IMAGE=ghcr.io/<your-org>/wolf-den:local-test"
Write-Host "   Then Reconfigure / deploy from plugin UI."
Write-Host ""
Write-Host " Verify dev server (after serve.ps1):" -ForegroundColor DarkGray
Write-Host "   curl -I http://${DevIp}:${DevPort}/gow-dev.plg"
Write-Host "   curl -I http://${DevIp}:${DevPort}/dist/settings-ui.txz"
Write-Host "   curl -I http://${DevIp}:${DevPort}/scripts/deploy.sh"
Write-Host "================================================================" -ForegroundColor Green
