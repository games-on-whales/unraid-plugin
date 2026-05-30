# Generate gow-dev.plg at repo root from gow.plg + local dev URLs.
param(
  [Parameter(Mandatory = $true)][string]$DevIp,
  [Parameter(Mandatory = $true)][int]$DevPort,
  [string]$DevVersion = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Src = Join-Path $RepoRoot "gow.plg"
$Dst = Join-Path $RepoRoot "gow-dev.plg"

if (-not (Test-Path $Src)) {
  throw "Missing gow.plg - run prepare.ps1 first."
}

if (-not $DevVersion) {
  $vars = Join-Path $RepoRoot "scripts\vars.sh"
  if (Test-Path $vars) {
    foreach ($line in Get-Content $vars) {
      if ($line -match '^export GOW_VERSION="(.+)"') {
        $v = $matches[1]
        # Unraid accepts YYYY.MM.DD or YYYY.MM.DDa hotfix suffixes.
        if ($v -match '^(\d+\.\d+\.\d+)([a-z])$') {
          $DevVersion = $Matches[1] + [char]([int][char]$Matches[2] + 1)
        } elseif ($v -match '^\d+\.\d+\.\d+$') {
          $DevVersion = $v + "a"
        } else {
          $DevVersion = $v
        }
        break
      }
    }
  }
  if (-not $DevVersion) { $DevVersion = "dev-local" }
}

$base = "http://${DevIp}:${DevPort}"
$lines = [System.Collections.Generic.List[string]]::new()
$inChanges = $false
$changesDone = $false

foreach ($line in Get-Content -Path $Src -Encoding UTF8) {
  if ($line -match '<CHANGES>') {
    $inChanges = $true
    $lines.Add('  <CHANGES><![CDATA[')
    $lines.Add("### $DevVersion (local dev build)")
    $lines.Add("- Served from $base")
    $lines.Add('- Cursor stack on fork/main - not for upstream release')
    $lines.Add('- After edits: prepare.ps1 -SkipGit, then dev-sync.sh on Unraid')
    $lines.Add(']]></CHANGES>')
    continue
  }
  if ($inChanges) {
    if ($line -match '</CHANGES>') {
      $inChanges = $false
      $changesDone = $true
    }
    continue
  }

  if ($line -match '<!ENTITY version\s+') {
    $lines.Add("<!ENTITY version   `"$DevVersion`">")
    continue
  }
  if ($line -match '<!ENTITY gitPkgURL\s+') {
    $lines.Add("<!ENTITY gitPkgURL `"$base`">")
    continue
  }
  if ($line -match '<!ENTITY gitReleaseURL\s+') {
    $lines.Add("<!ENTITY gitReleaseURL `"$base/dist`">")
    continue
  }
  if ($line -match '<!ENTITY pluginURL\s+') {
    $lines.Add("<!ENTITY pluginURL `"$base/gow-dev.plg`">")
    continue
  }
  $lines.Add($line)
}

if (-not $changesDone) {
  throw "Could not locate CHANGES block in gow.plg"
}

$text = ($lines -join "`n") + "`n"
[System.IO.File]::WriteAllText($Dst, $text, [System.Text.UTF8Encoding]::new($false))

if ([System.IO.File]::ReadAllText($Dst).Contains([char]13)) {
  throw 'gow-dev.plg contains CRLF - refuse to serve a broken plg'
}

Write-Host "Wrote $Dst (version: $DevVersion, base: $base, LF + CDATA CHANGES)"
