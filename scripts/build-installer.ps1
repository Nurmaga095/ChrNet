Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$releaseDir = Join-Path $projectRoot "build\windows\x64\runner\Release"
$xrayDistDir = Join-Path $projectRoot "tools\xray\dist"
$redistCacheDir = Join-Path $projectRoot "tools\redist"
$vcRedistPath = Join-Path $redistCacheDir "vc_redist.x64.exe"
$vcRedistUrl = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
$runnerResDir = Join-Path $projectRoot "windows\runner\resources"
$installerScript = Join-Path $projectRoot "windows\installer\chrnet.iss"
$outputDir = Join-Path $projectRoot "dist"

function Resolve-IsccPath {
    $cmd = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles}\Inno Setup 6\ISCC.exe"
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "ISCC.exe not found. Install Inno Setup 6: https://jrsoftware.org/isdl.php"
}

function Get-AppVersion {
    $pubspecPath = Join-Path $projectRoot "pubspec.yaml"
    $versionLine = Select-String -Path $pubspecPath -Pattern "^\s*version:\s*(.+)\s*$" | Select-Object -First 1
    if (-not $versionLine) {
        throw "Failed to read app version from pubspec.yaml"
    }
    $raw = $versionLine.Matches[0].Groups[1].Value.Trim()
    if ($raw -match "^([0-9]+\.[0-9]+\.[0-9]+)") {
        return $Matches[1]
    }
    throw "Unsupported version format in pubspec.yaml: $raw"
}

function Resolve-VCRedistPath {
    if (Test-Path $vcRedistPath) {
        return $vcRedistPath
    }

    if (-not (Test-Path $redistCacheDir)) {
        New-Item -ItemType Directory -Path $redistCacheDir | Out-Null
    }

    Write-Host "==> Downloading VC++ Redistributable (x64)"
    try {
        Invoke-WebRequest -Uri $vcRedistUrl -OutFile $vcRedistPath
    }
    catch {
        if (Test-Path $vcRedistPath) {
            Remove-Item $vcRedistPath -Force -ErrorAction SilentlyContinue
        }
        throw "Failed to download vc_redist.x64.exe. Download manually from $vcRedistUrl and place it at $vcRedistPath"
    }

    return $vcRedistPath
}

Write-Host "==> Flutter Windows release build"
Push-Location $projectRoot
try {
    flutter build windows --release
}
finally {
    Pop-Location
}

if (-not (Test-Path (Join-Path $releaseDir "chrnet.exe"))) {
    throw "Release build not found: $releaseDir"
}

if (-not (Test-Path $xrayDistDir)) {
    throw "Xray dist folder not found: $xrayDistDir"
}

Write-Host "==> Copying Xray runtime files"
$runtimeFiles = @("xray.exe", "wintun.dll", "geoip.dat", "geosite.dat")
foreach ($file in $runtimeFiles) {
    $source = Join-Path $xrayDistDir $file
    if (-not (Test-Path $source)) {
        throw "Missing runtime file: $source"
    }
    Copy-Item $source (Join-Path $releaseDir $file) -Force
}

$appIcon = Join-Path $runnerResDir "app_icon.ico"
if (Test-Path $appIcon) {
    Copy-Item $appIcon (Join-Path $releaseDir "app_icon.ico") -Force
}

if (-not (Test-Path $installerScript)) {
    throw "Installer script not found: $installerScript"
}

if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$iscc = Resolve-IsccPath
$appVersion = Get-AppVersion
$resolvedVcRedist = Resolve-VCRedistPath

Write-Host "==> Building installer (version $appVersion)"
& $iscc `
    "/DReleaseDir=$releaseDir" `
    "/DVCRedistPath=$resolvedVcRedist" `
    "/DAppVersion=$appVersion" `
    "/DOutputDir=$outputDir" `
    $installerScript

Write-Host ""
Write-Host "Installer ready in: $outputDir"
