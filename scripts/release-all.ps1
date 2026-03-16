Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$repo = "Nurmaga095/ChrNet"

function Get-AppVersion {
    $pubspecPath = Join-Path $projectRoot "pubspec.yaml"
    $versionLine = Select-String -Path $pubspecPath -Pattern "^\s*version:\s*([0-9]+\.[0-9]+\.[0-9]+)"
    if (-not $versionLine) {
        throw "Failed to read app version from $pubspecPath"
    }

    return $versionLine.Matches[0].Groups[1].Value
}

function Assert-CommandExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Remove-ReleaseAssetIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag,
        [Parameter(Mandatory = $true)]
        [string]$AssetName
    )

    $assetNames = gh release view $Tag --repo $repo --json assets --jq ".assets[].name"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read release assets for $Tag"
    }

    if ($assetNames -contains $AssetName) {
        Write-Host "==> Removing old asset: $AssetName"
        gh release delete-asset $Tag $AssetName --repo $repo --yes
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete asset $AssetName from $Tag"
        }
    }
}

function Ensure-ReleaseTagExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    $localTag = git tag --list $Tag
    if (-not $localTag) {
        $headCommit = git rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or -not $headCommit) {
            throw "Failed to resolve HEAD commit for tag creation"
        }

        Write-Host "==> Creating local git tag $Tag at $headCommit"
        git tag -a $Tag $headCommit -m "Release $Tag"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create local git tag: $Tag"
        }
    }

    $remoteTag = git ls-remote --tags origin "refs/tags/$Tag"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query remote tags for $Tag"
    }

    if (-not $remoteTag) {
        Write-Host "==> Pushing git tag $Tag to origin"
        git push origin "refs/tags/$Tag"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to push git tag: $Tag"
        }
    }
}

function Ensure-ReleaseExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    Write-Host "==> Checking release $Tag"
    gh release view $Tag --repo $repo | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host "==> Release $Tag not found, creating it"
    gh release create $Tag --repo $repo --verify-tag --title $Tag --notes "Release $Tag"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create GitHub release: $Tag"
    }
}

Assert-CommandExists "flutter"
Assert-CommandExists "gh"

Push-Location $projectRoot
try {
    $version = Get-AppVersion
    $tag = "v$version"
    $versionedInstaller = Join-Path $projectRoot "dist\ChrNet-Setup-$version.exe"
    $latestInstaller = Join-Path $projectRoot "dist\ChrNet-Setup-latest.exe"
    $apkPath = Join-Path $projectRoot "build\app\outputs\flutter-apk\app-release.apk"
    $installerScript = Join-Path $projectRoot "scripts\build-installer.ps1"

    Write-Host "==> Checking GitHub auth"
    gh auth status
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI is not authenticated"
    }

    Ensure-ReleaseTagExists -Tag $tag
    Ensure-ReleaseExists -Tag $tag

    Write-Host "==> Building Windows installer"
    powershell -ExecutionPolicy Bypass -File $installerScript
    if (-not (Test-Path $versionedInstaller)) {
        throw "Installer not found: $versionedInstaller"
    }

    Write-Host "==> Updating latest Windows installer"
    Copy-Item $versionedInstaller $latestInstaller -Force

    Write-Host "==> Building Android APK"
    flutter build apk --release
    if ($LASTEXITCODE -ne 0) {
        throw "Android APK build failed"
    }
    if (-not (Test-Path $apkPath)) {
        throw "APK not found: $apkPath"
    }

    Remove-ReleaseAssetIfExists -Tag $tag -AssetName "ChrNet-Setup-$version.exe"

    Write-Host "==> Uploading release assets"
    gh release upload $tag $latestInstaller $apkPath --repo $repo --clobber
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to upload release assets"
    }

    Write-Host ""
    Write-Host "Release updated:"
    Write-Host "  Tag: $tag"
    Write-Host "  Asset: ChrNet-Setup-latest.exe"
    Write-Host "  Asset: app-release.apk"
}
finally {
    Pop-Location
}
