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
try {
    $env:T3CODE_DESKTOP_OUTPUT_DIR = $output
    $env:T3CODE_DESKTOP_UPDATE_REPOSITORY = $Repository
    $target = if ($Platform -eq 'windows') { @('--platform', 'win', '--target', 'nsis', '--arch', 'x64') } else { @('--platform', 'linux', '--target', 'appimage', '--arch', 'x64') }
    Invoke-Captured -Label 'package-desktop' -WorkingDirectory $SourceDir -FilePath 'vp' -Arguments (@('run', 'dist:desktop:artifact') + $target + @('--build-version', $Version))
}
finally {
    if ($null -eq $oldOutput) { Remove-Item Env:T3CODE_DESKTOP_OUTPUT_DIR -ErrorAction SilentlyContinue } else { $env:T3CODE_DESKTOP_OUTPUT_DIR = $oldOutput }
    if ($null -eq $oldRepository) { Remove-Item Env:T3CODE_DESKTOP_UPDATE_REPOSITORY -ErrorAction SilentlyContinue } else { $env:T3CODE_DESKTOP_UPDATE_REPOSITORY = $oldRepository }
}

$assetCount = @(Get-ChildItem -LiteralPath $output -File -ErrorAction SilentlyContinue).Count
if ($assetCount -lt 1) { throw 'The desktop package produced no release assets.' }
Write-Host "DRY RUN: $Platform package completed with $assetCount release asset(s); nothing was uploaded."
