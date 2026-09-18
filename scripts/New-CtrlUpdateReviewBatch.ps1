<#
.SYNOPSIS
    Selecteert alleen nieuwe of inhoudelijk gewijzigde items voor cloudreview.
#>
[CmdletBinding()]
param(
    [string] $InputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/review-input.json'),
    [string] $CachePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/review-cache.json'),
    [string] $OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.tmp/review-pending.json')
)

$ErrorActionPreference = 'Stop'

$inputData = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$cacheById = @{}
if (Test-Path -LiteralPath $CachePath) {
    $cache = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in @($cache.items)) {
        if ($item.id) { $cacheById[[string]$item.id] = $item }
    }
}

$pending = @($inputData.items | Where-Object {
    $id = [string]$_.id
    -not $cacheById.ContainsKey($id) -or
    [string]$cacheById[$id].contentHash -ne [string]$_.contentHash -or
    [string]::IsNullOrWhiteSpace([string]$cacheById[$id].titleEn) -or
    [string]::IsNullOrWhiteSpace([string]$cacheById[$id].summaryEn) -or
    [string]::IsNullOrWhiteSpace([string]$cacheById[$id].reasonEn) -or
    [string]$cacheById[$id].urgency -notin @('critical', 'high', 'normal', 'low') -or
    [string]$cacheById[$id].tenantRelevance -notin @('confirmed', 'likely', 'unknown', 'notApplicable') -or
    [string]::IsNullOrWhiteSpace([string]$cacheById[$id].tenantReasonNl) -or
    [string]::IsNullOrWhiteSpace([string]$cacheById[$id].tenantReasonEn)
})

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
}

[PSCustomObject]@{ items = $pending } |
    ConvertTo-Json -Depth 10 |
    Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Host "Cloudreview nodig voor $($pending.Count) van $(@($inputData.items).Count) items."
Write-Output $pending.Count
