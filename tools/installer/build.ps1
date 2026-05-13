#requires -Version 5.1
<#
.SYNOPSIS
  Build the Lumen Windows installer.

.DESCRIPTION
  Wrapper around `flutter build windows --release` followed by Inno
  Setup's `iscc`. Reads the version from pubspec.yaml so we only have
  to bump it in one place per release.

  Outputs:
    - dist\Lumen-Setup-v<version>.exe   (Inno installer)
    - dist\lumen-v<version>-windows-x64.zip   (portable zip)

  The .exe is what `lib/services/update_service.dart` downloads from
  the GitHub Releases page on auto-update.

.PARAMETER SkipBuild
  Reuse the existing build\windows\x64\runner\Release output instead
  of running `flutter build windows --release`. Useful when iterating
  on the installer script itself.

.PARAMETER NoZip
  Skip the portable .zip -- sometimes you just want the installer.

.PARAMETER Iscc
  Path to Inno Setup's `iscc.exe`. If omitted, the script probes the
  standard install locations for Inno Setup 6 and 7 (under both
  Program Files and Program Files (x86)), then falls back to PATH.

.EXAMPLE
  tools\installer\build.ps1

.EXAMPLE
  tools\installer\build.ps1 -SkipBuild

.NOTES
  Requires Inno Setup 6 or 7 to be installed:
    https://jrsoftware.org/isdl.php
#>

[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$NoZip,
    [string]$Iscc
)

$ErrorActionPreference = "Stop"

# Probe the well-known Inno Setup install locations + PATH. We accept
# both major versions (6 and 7) because Inno Setup 7's compiler is
# backwards-compatible with 6 .iss syntax -- our script doesn't use any
# 7-only features. Order matters: caller-supplied path first, then
# newest first.
function Resolve-Iscc {
    param([string]$Override)
    if ($Override) {
        if (Test-Path $Override) { return (Resolve-Path $Override).Path }
        Write-Error "Inno Setup not found at -Iscc path: $Override"
        exit 1
    }
    $candidates = @(
        "$env:ProgramFiles\Inno Setup 7\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 7\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $onPath = Get-Command iscc -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    return $null
}

# Repo root is two levels up from this script (tools\installer\).
$repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
Set-Location $repoRoot

# Read version from pubspec.yaml. Format: `version: 1.0.12+12`
$pubspec = Get-Content "$repoRoot\pubspec.yaml" -Raw
if ($pubspec -notmatch '(?m)^version:\s+(\d+\.\d+\.\d+)\+\d+') {
    Write-Error "Could not parse version: line from pubspec.yaml"
    exit 1
}
$version = $matches[1]
Write-Host ""
Write-Host "Lumen installer build" -ForegroundColor Cyan
Write-Host "  version : $version"
Write-Host "  repo    : $repoRoot"
Write-Host ""

# 1. flutter build windows --release
if (-not $SkipBuild) {
    Write-Host "[1/3] flutter build windows --release ..." -ForegroundColor Cyan
    # Some Flutter plugin build scripts (notably super_native_extensions'
    # cargokit/resolve_symlinks.ps1) write benign warnings to stderr when
    # a Rust target symlink is stale. With $ErrorActionPreference=Stop
    # those warnings become terminating PowerShell errors even though
    # flutter itself exits 0. Relax error handling for just the flutter
    # call and gate exclusively on the real exit code.
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & flutter build windows --release 2>&1 | ForEach-Object { Write-Host $_ }
        $flutterExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevPref
    }
    if ($flutterExit -ne 0) {
        Write-Error "flutter build failed (exit $flutterExit)"
        exit $flutterExit
    }
}
else {
    Write-Host "[1/3] (skipped -- using existing build output)" -ForegroundColor Yellow
}

$releaseDir = "$repoRoot\build\windows\x64\runner\Release"
if (-not (Test-Path "$releaseDir\lumen.exe")) {
    Write-Error "Release build not found at $releaseDir\lumen.exe -- run without -SkipBuild first."
    exit 1
}

# Make sure dist/ exists. .gitignore should already cover this folder,
# but New-Item -Force is harmless if it doesn't.
$distDir = "$repoRoot\dist"
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# 2. ISCC (Inno Setup Compiler).
Write-Host ""
Write-Host "[2/3] iscc lumen.iss /DAppVersion=$version ..." -ForegroundColor Cyan
$resolvedIscc = Resolve-Iscc -Override $Iscc
if (-not $resolvedIscc) {
    Write-Error "Inno Setup not found. Install Inno Setup 6 or 7 from https://jrsoftware.org/isdl.php, or pass -Iscc <path>."
    exit 1
}
Write-Host "       iscc : $resolvedIscc" -ForegroundColor DarkGray
& $resolvedIscc "/DAppVersion=$version" "$PSScriptRoot\lumen.iss"
if ($LASTEXITCODE -ne 0) {
    Write-Error "iscc failed (exit $LASTEXITCODE)"
    exit $LASTEXITCODE
}

$setupExe = "$distDir\Lumen-Setup-v$version.exe"
if (-not (Test-Path $setupExe)) {
    Write-Error "Expected installer at $setupExe -- iscc reported success but file is missing."
    exit 1
}
$setupBytes = (Get-Item $setupExe).Length
Write-Host "       -> $setupExe ($([math]::Round($setupBytes / 1MB, 2)) MB)" -ForegroundColor Green

# 3. Portable zip (matches the legacy release artefact shape).
if (-not $NoZip) {
    Write-Host ""
    Write-Host "[3/3] zip portable ..." -ForegroundColor Cyan
    $zipPath = "$distDir\lumen-v$version-windows-x64.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    # Compress-Archive doesn't follow symlinks and keeps relative
    # paths inside the zip starting from the source directory's
    # immediate children -- exactly the layout we want.
    Compress-Archive -Path "$releaseDir\*" -DestinationPath $zipPath -CompressionLevel Optimal
    $zipBytes = (Get-Item $zipPath).Length
    Write-Host "       -> $zipPath ($([math]::Round($zipBytes / 1MB, 2)) MB)" -ForegroundColor Green
}
else {
    Write-Host "[3/3] (skipped -- -NoZip)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "Upload both artefacts to the GitHub release:" -ForegroundColor Cyan
Write-Host "  $setupExe"
if (-not $NoZip) {
    Write-Host "  $distDir\lumen-v$version-windows-x64.zip"
}
Write-Host ""
Write-Host "The auto-update path in lib/services/update_service.dart looks"
Write-Host "for the .exe asset whose name matches `^Lumen-Setup-.*\.exe`,"
Write-Host "so don't rename the installer when uploading."
