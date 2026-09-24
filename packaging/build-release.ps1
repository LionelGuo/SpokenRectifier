# Builds the SpokenRectifier release artifacts into <repo>\dist:
#   SpokenRectifier-Setup-<version>.exe   Inno Setup per-user installer (primary)
#   SpokenRectifier-<version>-win64.zip   portable build (secondary)
#   SHA256SUMS.txt                        checksums for both
#
# Usage (from the repository root, on Windows):
#   powershell -ExecutionPolicy Bypass -File packaging\build-release.ps1
#
# The version is read from app\pubspec.yaml (single source of truth; the
# about pane paints the Rust crate version, which is kept in step with it).
# Requires the Flutter and Inno Setup 6 toolchains on PATH or default paths.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$pubspec = Get-Content (Join-Path $root 'app\pubspec.yaml') -Raw
if ($pubspec -notmatch '(?m)^version:\s*(\d+\.\d+\.\d+)\+') {
    throw 'cannot parse version from app\pubspec.yaml'
}
$version = $Matches[1]
Write-Host "version: $version"

# 1. Release build.
Push-Location (Join-Path $root 'app')
try {
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows --release failed' }
} finally {
    Pop-Location
}
$releaseDir = Join-Path $root 'app\build\windows\x64\runner\Release'

# 2. Locate the Inno Setup compiler.
$iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    $iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
}
if (-not $iscc) {
    throw 'Inno Setup 6 not found (https://jrsoftware.org/isdl.php)'
}

# 3. Clean staging: the Release directory can pick up runtime artifacts from
# dev runs launched there (local store db, perf log, local config overrides);
# none of those may ship. Both the installer and the zip build from the
# staged copy, and a leftover guard fails the build on anything personal.
$dist = Join-Path $root 'dist'
$stageRoot = Join-Path $dist 'release-stage'
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
$payload = Join-Path $stageRoot 'payload'
New-Item -ItemType Directory -Force -Path $payload | Out-Null
Copy-Item "$releaseDir\*" $payload -Recurse
Get-ChildItem $payload -Recurse -File |
    Where-Object { $_.Name -match '^(spokenrectifier-(store|history)\.db|spokenrectifier-perf\.log|spokenrectifier-ui\.toml)$' -or $_.Name -like '*.local.toml' } |
    Remove-Item -Force
$leftovers = Get-ChildItem $payload -Recurse -File -Include '*.local.toml', 'spokenrectifier-*.db'
if ($leftovers) {
    throw "personal artifacts survived staging: $($leftovers.Name -join ', ')"
}

# 4. Installer.
& $iscc "/DMyAppVersion=$version" (Join-Path $PSScriptRoot 'spokenrectifier.iss') | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'ISCC failed' }

# 5. Portable zip with a single top-level directory.
$zipName = "SpokenRectifier-$version-win64"
$zipStageRoot = Join-Path $dist 'zip-stage'
if (Test-Path $zipStageRoot) { Remove-Item -Recurse -Force $zipStageRoot }
$zipStage = Join-Path $zipStageRoot $zipName
New-Item -ItemType Directory -Force -Path $zipStage | Out-Null
Copy-Item "$payload\*" $zipStage -Recurse
Compress-Archive -Path $zipStage -DestinationPath (Join-Path $dist "$zipName.zip") -Force
Remove-Item -Recurse -Force $zipStageRoot
Remove-Item -Recurse -Force $stageRoot

# 6. Checksums (sha256sum-compatible format).
$artifacts = @("SpokenRectifier-Setup-$version.exe", "$zipName.zip")
$lines = foreach ($name in $artifacts) {
    $hash = (Get-FileHash (Join-Path $dist $name) -Algorithm SHA256).Hash.ToLower()
    "$hash  $name"
}
$lines | Set-Content (Join-Path $dist 'SHA256SUMS.txt') -Encoding ascii
Write-Host ''
Write-Host 'done:'
$lines | ForEach-Object { Write-Host "  dist\$_" }
