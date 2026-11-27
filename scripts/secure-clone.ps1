[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Owner,
    [Parameter(Mandatory = $true)] [string] $Name,
    [Parameter(Mandatory = $true)] [string] $Token,
    [Parameter(Mandatory = $true)] [string] $Destination,
    [string] $Revision,
    [string] $Branch,
    [int] $PullNumber = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Owner -notmatch '^[A-Za-z0-9_.-]+$' -or $Name -notmatch '^[A-Za-z0-9_.-]+$') {
    throw 'Private repository identity is invalid.'
}
if (-not $Token) { throw 'Private repository token is missing.' }

$repo = "$Owner/$Name"
$url = "https://github.com/$repo.git"
Write-Output "::add-mask::$Owner"
Write-Output "::add-mask::$Name"
Write-Output "::add-mask::$repo"
Write-Output "::add-mask::$url"

$log = Join-Path $env:RUNNER_TEMP 'private-clone.log'
if (Test-Path -LiteralPath $Destination) {
    Remove-Item -LiteralPath $Destination -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null

$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$Token"))
$oldConfigCount = $env:GIT_CONFIG_COUNT
$oldConfigKey = $env:GIT_CONFIG_KEY_0
$oldConfigValue = $env:GIT_CONFIG_VALUE_0
$oldPrompt = $env:GIT_TERMINAL_PROMPT

try {
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = 'http.https://github.com/.extraheader'
    $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $auth"
    $env:GIT_TERMINAL_PROMPT = '0'

    $cloneArgs = @('clone', '--quiet', '--no-tags', '--depth', '1')
    if ($Branch -and -not $PullNumber -and -not $Revision) { $cloneArgs += @('--branch', $Branch) }
    $cloneArgs += @($url, $Destination)
    & git @cloneArgs *> $log
    if ($LASTEXITCODE -ne 0) { throw 'clone' }

    if ($PullNumber -gt 0) {
        & git -C $Destination fetch --quiet --no-tags --depth 1 origin "refs/pull/$PullNumber/head:refs/remotes/origin/pr-$PullNumber" *> $log
        if ($LASTEXITCODE -ne 0) { throw 'pull' }
        & git -C $Destination checkout --quiet --detach "refs/remotes/origin/pr-$PullNumber" *> $log
        if ($LASTEXITCODE -ne 0) { throw 'checkout' }
    } elseif ($Revision) {
        & git -C $Destination fetch --quiet --no-tags --depth 1 origin $Revision *> $log
        if ($LASTEXITCODE -ne 0) { throw 'revision' }
        & git -C $Destination checkout --quiet --detach FETCH_HEAD *> $log
        if ($LASTEXITCODE -ne 0) { throw 'checkout' }
    }

    if ($Revision) {
        $actual = (& git -C $Destination rev-parse HEAD 2>$null).Trim()
        if ($actual -ne $Revision) { throw 'identity' }
    }

    # Do not leave the private remote URL in the checkout used by build tools.
    & git -C $Destination remote remove origin *> $log
    if ($LASTEXITCODE -ne 0) { throw 'remote' }
}
catch {
    throw 'Private checkout failed; details are intentionally suppressed.'
}
finally {
    if ($null -eq $oldConfigCount) { Remove-Item Env:GIT_CONFIG_COUNT -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_COUNT = $oldConfigCount }
    if ($null -eq $oldConfigKey) { Remove-Item Env:GIT_CONFIG_KEY_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_KEY_0 = $oldConfigKey }
    if ($null -eq $oldConfigValue) { Remove-Item Env:GIT_CONFIG_VALUE_0 -ErrorAction SilentlyContinue } else { $env:GIT_CONFIG_VALUE_0 = $oldConfigValue }
    if ($null -eq $oldPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue } else { $env:GIT_TERMINAL_PROMPT = $oldPrompt }
}
