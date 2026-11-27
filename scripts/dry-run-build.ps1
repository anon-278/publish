[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ManagerDir,
    [Parameter(Mandatory = $true)] [string] $SourceDir,
    [Parameter(Mandatory = $true)] [ValidateSet('windows', 'linux')] [string] $Platform,
    [Parameter(Mandatory = $true)] [string] $Version,
    [Parameter(Mandatory = $true)] [string] $Repository,
    [switch] $FullBuild,
    [switch] $SkipApply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Repository -notmatch '^[^/\s]+/[^/\s]+$') { throw 'Public release repository is invalid.' }
$logRoot = Join-Path $env:RUNNER_TEMP "t3-dry-run-logs-$Platform"
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null

function Invoke-Captured {
    param(
        [Parameter(Mandatory = $true)] [string] $Label,
        [Parameter(Mandatory = $true)] [string] $WorkingDirectory,
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [Parameter(Mandatory = $true)] [string[]] $Arguments
    )

    $safeLabel = $Label -replace '[^A-Za-z0-9_.-]', '_'
    $log = Join-Path $logRoot "$safeLabel.log"
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $FilePath @Arguments *> $log
        if ($LASTEXITCODE -ne 0) { throw "$Label failed" }
    }
    catch {
        $stage = switch ($Label) {
            'apply-patches' { 'apply'; break }
            'install-dependencies' { 'install'; break }
            'verify-source' { 'typecheck'; break }
            'stamp-version' { 'stamp'; break }
            'package-desktop' { 'package'; break }
            default { $safeLabel; break }
        }
        Write-Host "DRY RUN ERROR CATEGORY: $stage-$Platform"
        throw "Build stage '$stage' failed; details are suppressed."
    }
    finally {
        Pop-Location
    }
}

$apply = Join-Path $ManagerDir 'scripts/apply-patches.ps1'
$verify = Join-Path $ManagerDir 'scripts/verify.ps1'
if (-not (Test-Path -LiteralPath $apply) -or -not (Test-Path -LiteralPath $verify)) {
    throw 'The private checkout is missing the expected patch-manager scripts.'
}

# All output from patch application, package installation, typechecking and
# packaging stays in runner-temp files and is never printed or uploaded.
if (-not $SkipApply) {
    Invoke-Captured -Label 'apply-patches' -WorkingDirectory $ManagerDir -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $apply, '-SourceDir', $SourceDir)
}
Invoke-Captured -Label 'install-dependencies' -WorkingDirectory $SourceDir -FilePath 'vp' -Arguments @('i')
Invoke-Captured -Label 'verify-source' -WorkingDirectory $ManagerDir -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $verify, '-SourceDir', $SourceDir, '-SkipTests', '-SkipBuild')

if (-not $FullBuild) {
    Write-Host "DRY RUN: $Platform patch application and source verification passed. Packaging was not requested."
    exit 0
}

Invoke-Captured -Label 'stamp-version' -WorkingDirectory $SourceDir -FilePath 'node' -Arguments @('scripts/update-release-package-versions.ts', $Version)

$output = Join-Path $env:RUNNER_TEMP "release-out-$Platform"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$oldOutput = $env:T3CODE_DESKTOP_OUTPUT_DIR
$oldRepository = $env:T3CODE_DESKTOP_UPDATE_REPOSITORY
$oldBuildPlatform = $env:BUILD_PLATFORM
$oldCliPlatform = $env:CLI_PLATFORM
$oldBuildTarget = $env:BUILD_TARGET
try {
    $env:T3CODE_DESKTOP_OUTPUT_DIR = $output
    $env:T3CODE_DESKTOP_UPDATE_REPOSITORY = $Repository
    $env:BUILD_PLATFORM = $Platform
    $env:CLI_PLATFORM = if ($Platform -eq 'windows') { 'win' } else { 'linux' }
    $env:BUILD_TARGET = if ($Platform -eq 'windows') { 'nsis' } else { 'AppImage' }
    $target = @('--platform', $env:CLI_PLATFORM, '--target', $env:BUILD_TARGET, '--arch', 'x64', '--verbose')
    Invoke-Captured -Label 'package-desktop' -WorkingDirectory $SourceDir -FilePath 'vp' -Arguments (@('run', 'dist:desktop:artifact') + $target + @('--build-version', $Version))
}
finally {
    if ($null -eq $oldOutput) { Remove-Item Env:T3CODE_DESKTOP_OUTPUT_DIR -ErrorAction SilentlyContinue } else { $env:T3CODE_DESKTOP_OUTPUT_DIR = $oldOutput }
    if ($null -eq $oldRepository) { Remove-Item Env:T3CODE_DESKTOP_UPDATE_REPOSITORY -ErrorAction SilentlyContinue } else { $env:T3CODE_DESKTOP_UPDATE_REPOSITORY = $oldRepository }
    if ($null -eq $oldBuildPlatform) { Remove-Item Env:BUILD_PLATFORM -ErrorAction SilentlyContinue } else { $env:BUILD_PLATFORM = $oldBuildPlatform }
    if ($null -eq $oldCliPlatform) { Remove-Item Env:CLI_PLATFORM -ErrorAction SilentlyContinue } else { $env:CLI_PLATFORM = $oldCliPlatform }
    if ($null -eq $oldBuildTarget) { Remove-Item Env:BUILD_TARGET -ErrorAction SilentlyContinue } else { $env:BUILD_TARGET = $oldBuildTarget }
}

$assetCount = @(Get-ChildItem -LiteralPath $output -File -ErrorAction SilentlyContinue).Count
if ($assetCount -lt 1) {
    Write-Host "DRY RUN ERROR CATEGORY: assets-$Platform"
    throw 'The desktop package produced no release assets.'
}
if ($Platform -eq 'windows') {
    $exe = Get-ChildItem -LiteralPath $output -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe -or -not (Test-Path -LiteralPath "$($exe.FullName).blockmap") -or -not (Test-Path -LiteralPath (Join-Path $output 'latest.yml'))) {
        Write-Host 'DRY RUN ERROR CATEGORY: assets-windows'
        throw 'The Windows package is missing an installer, blockmap, or latest.yml.'
    }
}
else {
    if (-not (Get-ChildItem -LiteralPath $output -Filter '*.AppImage' -File -ErrorAction SilentlyContinue | Select-Object -First 1) -or -not (Test-Path -LiteralPath (Join-Path $output 'latest-linux.yml'))) {
        Write-Host 'DRY RUN ERROR CATEGORY: assets-linux'
        throw 'The Linux package is missing an AppImage or latest-linux.yml.'
    }
}
Write-Host "DRY RUN: $Platform package completed with $assetCount release asset(s); nothing was uploaded."
