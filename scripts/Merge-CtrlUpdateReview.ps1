<#
.SYNOPSIS
    Valideert een cloudreview en voegt die atomair samen met de bestaande cache.
#>
[CmdletBinding()]
param(
    [string] $InputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/review-input.json'),
    [string] $PendingPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.tmp/review-pending.json'),
    [string] $ResultPath = (Join-Path (Split-Path -Parent $PSScriptRoot) '.tmp/review-result.json'),
    [string] $CachePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/review-cache.json'),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/sources.json')
)

$ErrorActionPreference = 'Stop'

$inputData = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$pendingData = Get-Content -LiteralPath $PendingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$resultData = Get-Content -LiteralPath $ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$allowedCategories = @($config.categories.PSObject.Properties.Name)

$cacheById = @{}
if (Test-Path -LiteralPath $CachePath) {
    $cache = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($item in @($cache.items)) {
        if ($item.id) { $cacheById[[string]$item.id] = $item }
    }
}

$expectedById = @{}
foreach ($item in @($pendingData.items)) {
    $expectedById[[string]$item.id] = [string]$item.contentHash
}

$receivedById = @{}
foreach ($review in @($resultData.items)) {
    $id = [string]$review.id
    if (-not $expectedById.ContainsKey($id)) { throw "Onverwacht reviewitem ontvangen: $id" }
    if ($receivedById.ContainsKey($id)) { throw "Dubbel reviewitem ontvangen: $id" }

    # contentHash is pipeline-metadata, geen redactioneel oordeel. Structured
    # output kan een lange hash incidenteel verkeerd terugkopiëren. Het bekende
    # item-id blijft streng gevalideerd; daarna zetten we de hash deterministisch
    # terug vanuit dezelfde pending momentopname. Onbekende, dubbele of
    # ontbrekende ids blijven daardoor een harde fout.
    if ([string]$review.contentHash -ne $expectedById[$id]) {
        Write-Warning "contentHash door pipeline hersteld voor: $id"
        $review.contentHash = $expectedById[$id]
    }

    $categories = @($review.categories | Where-Object { $_ -in $allowedCategories } | Select-Object -Unique)
    if ($categories.Count -lt 1 -or $categories.Count -gt 3) { throw "Ongeldige categorieën voor: $id" }
    if ([string]::IsNullOrWhiteSpace([string]$review.titleNl) -or
        [string]::IsNullOrWhiteSpace([string]$review.summaryNl) -or
        [string]::IsNullOrWhiteSpace([string]$review.titleEn) -or
        [string]::IsNullOrWhiteSpace([string]$review.summaryEn) -or
        [string]::IsNullOrWhiteSpace([string]$review.reasonNl) -or
        [string]::IsNullOrWhiteSpace([string]$review.reasonEn)) {
        throw "Onvolledig reviewitem ontvangen: $id"
    }

    $review.categories = $categories
    $receivedById[$id] = $review
}

if ($receivedById.Count -ne $expectedById.Count) {
    $missing = @($expectedById.Keys | Where-Object { -not $receivedById.ContainsKey($_) })
    throw "Cloudreview is onvolledig. Ontbrekend: $($missing -join ', ')"
}

foreach ($id in $receivedById.Keys) { $cacheById[$id] = $receivedById[$id] }

$ordered = @($inputData.items | ForEach-Object {
    $id = [string]$_.id
    if (-not $cacheById.ContainsKey($id)) { throw "Geen review beschikbaar voor actueel item: $id" }
    $cached = $cacheById[$id]
    if ([string]$cached.contentHash -ne [string]$_.contentHash) { throw "Verouderde reviewcache voor: $id" }
    $cached
})

$result = [PSCustomObject]@{
    generated = (Get-Date).ToUniversalTime().ToString('o')
    items = $ordered
}
$temporaryPath = "$CachePath.tmp"
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
$null = Get-Content -LiteralPath $temporaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
Move-Item -LiteralPath $temporaryPath -Destination $CachePath -Force

Write-Host "Reviewcache atomair bijgewerkt: $($ordered.Count) items." -ForegroundColor Green
