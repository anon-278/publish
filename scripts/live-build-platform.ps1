[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ManagerDir,
    [Parameter(Mandatory = $true)] [string] $SourceDir,
    [Parameter(Mandatory = $true)] [ValidateSet('windows', 'linux')] [string] $Platform,
    [Parameter(Mandatory = $true)] [string] $Version,
    [Parameter(Mandatory = $true)] [string] $Repository,
    [switch] $SkipApply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Repository -notmatch '^[^/\s]+/[^/\s]+$') { throw 'Public release repository is invalid.' }
if ($Version -notmatch '^\d+\.\d+\.\d+-\d+$') { throw 'Release version is invalid.' }
$logRoot = Join-Path $env:RUNNER_TEMP "t3-live-logs-$Platform"
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
    finally {
        Pop-Location
    }
}

$apply = Join-Path $ManagerDir 'scripts/apply-patches.ps1'
$verify = Join-Path $ManagerDir 'scripts/verify.ps1'
if (-not (Test-Path -LiteralPath $apply) -or -not (Test-Path -LiteralPath $verify)) {
    throw 'The private checkout is missing the expected build scripts.'
}

if (-not $SkipApply) {
    Invoke-Captured -Label 'apply-patches' -WorkingDirectory $ManagerDir -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $apply, '-SourceDir', $SourceDir)
}
Invoke-Captured -Label 'install-dependencies' -WorkingDirectory $SourceDir -FilePath 'vp' -Arguments @('i')
Invoke-Captured -Label 'verify-source' -WorkingDirectory $ManagerDir -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $verify, '-SourceDir', $SourceDir, '-SkipTests', '-SkipBuild')
Invoke-Captured -Label 'stamp-version' -WorkingDirectory $SourceDir -FilePath 'node' -Arguments @('scripts/update-release-package-versions.ts', $Version)

$cliPlatform = if ($Platform -eq 'windows') { 'win' } else { 'linux' }
$rustTarget = if ($Platform -eq 'windows') { 'x86_64-pc-windows-msvc' } else { 'x86_64-unknown-linux-gnu' }
$buildTarget = if ($Platform -eq 'windows') { 'nsis' } else { 'AppImage' }
$desktopOutput = Join-Path $env:RUNNER_TEMP "release-out-$Platform"
$cliOutput = Join-Path $env:RUNNER_TEMP "release-cli-$Platform"
New-Item -ItemType Directory -Force -Path $desktopOutput, $cliOutput | Out-Null

$oldValues = @{
    T3CODE_DESKTOP_OUTPUT_DIR = $env:T3CODE_DESKTOP_OUTPUT_DIR
    T3CODE_DESKTOP_UPDATE_REPOSITORY = $env:T3CODE_DESKTOP_UPDATE_REPOSITORY
    BUILD_PLATFORM = $env:BUILD_PLATFORM
    CLI_PLATFORM = $env:CLI_PLATFORM
    RUST_TARGET = $env:RUST_TARGET
    BUILD_TARGET = $env:BUILD_TARGET
    T3CODE_TELEMETRY_CHANNEL = $env:T3CODE_TELEMETRY_CHANNEL
}
try {
    $env:T3CODE_DESKTOP_OUTPUT_DIR = $desktopOutput
    $env:T3CODE_DESKTOP_UPDATE_REPOSITORY = $Repository
    $env:BUILD_PLATFORM = $Platform
    $env:CLI_PLATFORM = $cliPlatform
    $env:RUST_TARGET = $rustTarget
    $env:BUILD_TARGET = $buildTarget

    $desktopArgs = @('run', 'dist:desktop:artifact', '--platform', $cliPlatform, '--target', $buildTarget, '--arch', 'x64', '--verbose', '--build-version', $Version)
    try {
        Invoke-Captured -Label 'package-desktop' -WorkingDirectory $SourceDir -FilePath 'vp' -Arguments $desktopArgs
    }
    catch {
        Write-Host "LIVE RELEASE ERROR CATEGORY: package-desktop-command-$Platform"
        throw 'Desktop packaging failed; details are suppressed.'
    }

    $monitor = Join-Path $SourceDir "native/resource-monitor/target/$rustTarget/release"
    if (-not (Test-Path -LiteralPath $monitor)) {
        Write-Host "LIVE RELEASE ERROR CATEGORY: cli-resource-monitor-$Platform"
        throw 'The native resource monitor output is missing.'
    }

    $env:T3CODE_TELEMETRY_CHANNEL = 'stable'
    try {
        Invoke-Captured -Label 'build-cli-executable' -WorkingDirectory $SourceDir -FilePath 'node' -Arguments @('apps/server/scripts/cli.ts', 'build-exe', '--verbose')
    }
    catch {
        Write-Host "LIVE RELEASE ERROR CATEGORY: cli-executable-$Platform"
        throw 'CLI executable build failed; details are suppressed.'
    }

    try {
        Invoke-Captured -Label 'build-cli-archive' -WorkingDirectory $SourceDir -FilePath 'node' -Arguments @('scripts/build-cli-archive.ts', '--platform', $cliPlatform, '--arch', 'x64', '--version', $Version, '--resource-monitor-dir', $monitor, '--output-dir', $cliOutput)
    }
    catch {
        Write-Host "LIVE RELEASE ERROR CATEGORY: cli-archive-$Platform"
        throw 'CLI archive build failed; details are suppressed.'
    }

    $expectedCli = if ($Platform -eq 'windows') { "t3-$Version-win32-x64.zip" } else { "t3-$Version-linux-x64.tar.gz" }
    $cliArchive = Get-Item -LiteralPath (Join-Path $cliOutput $expectedCli) -ErrorAction SilentlyContinue
    if (-not $cliArchive) {
        Write-Host "LIVE RELEASE ERROR CATEGORY: cli-assets-$Platform"
        throw 'The expected CLI archive was not produced.'
    }
    try {
        Invoke-Captured -Label 'smoke-cli-archive' -WorkingDirectory $SourceDir -FilePath 'node' -Arguments @('scripts/smoke-cli-archive.ts', '--archive', $cliArchive.FullName, '--expect-version', $Version)
    }
    catch {
        Write-Host "LIVE RELEASE ERROR CATEGORY: cli-smoke-$Platform"
        throw 'CLI archive smoke test failed; details are suppressed.'
    }
}
finally {
    foreach ($name in $oldValues.Keys) {
        $old = $oldValues[$name]
        if ($null -eq $old) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue } else { Set-Item "Env:$name" $old }
    }
}

$assetDir = Join-Path $env:RUNNER_TEMP "release-assets-$Platform"
if (Test-Path -LiteralPath $assetDir) { Remove-Item -LiteralPath $assetDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $assetDir | Out-Null

if ($Platform -eq 'windows') {
    $required = @(
        "T3-Code-$Version-x64.exe",
        "T3-Code-$Version-x64.exe.blockmap",
        'latest.yml',
        $expectedCli
    )
}
else {
    # AppImage updates do not use a separate blockmap; latest-linux.yml is the feed.
    $required = @('T3-Code-x86_64.AppImage', 'latest-linux.yml', $expectedCli)
}

foreach ($name in $required) {
    $source = if ($name -like 't3-*') { Join-Path $cliOutput $name } else { Join-Path $desktopOutput $name }
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host "LIVE RELEASE ERROR CATEGORY: release-assets-$Platform"
        throw 'A required release asset is missing.'
    }
    Copy-Item -LiteralPath $source -Destination $assetDir
}

"asset_dir=$assetDir" >> $env:GITHUB_OUTPUT
Write-Host "Prepared $($required.Count) $Platform release assets for draft upload."
