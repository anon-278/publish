[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Owner,
    [Parameter(Mandatory = $true)] [string] $Name,
    [Parameter(Mandatory = $true)] [string] $Token,
    [Parameter(Mandatory = $true)] [int] $Number
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Owner -notmatch '^[A-Za-z0-9_.-]+$' -or $Name -notmatch '^[A-Za-z0-9_.-]+$' -or $Number -lt 1) {
    throw 'Private pull request identity is invalid.'
}

$repo = "$Owner/$Name"
$uri = "https://api.github.com/repos/$repo/pulls/$Number"

try {
    $headers = @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $Token"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $pr = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
}
catch {
    throw 'Private pull request lookup failed; details are intentionally suppressed.'
}

if ($pr.state -ne 'open') { throw 'The requested pull request is not open.' }
if (-not $pr.head.sha) { throw 'The requested pull request has no head SHA.' }
$headRepo = if ($pr.head.repo) { [string]$pr.head.repo.full_name } else { '' }

[ordered]@{
    number = [int]$pr.number
    headSha = [string]$pr.head.sha
    baseRef = [string]$pr.base.ref
    draft = [bool]$pr.draft
    crossRepository = [bool]($headRepo -and $headRepo -ne $repo)
} | ConvertTo-Json -Compress
