<#
.SYNOPSIS
    Voert snelle, netwerkloze kwaliteitscontroles uit op de repository.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string] $Message)
    $failures.Add($Message)
    Write-Host "[FOUT] $Message" -ForegroundColor Red
}

function Write-Pass {
    param([string] $Message)
    Write-Host "[OK]   $Message" -ForegroundColor Green
}

$requiredFiles = @(
    'config/sources.json',
    'data/state.json',
    'data/review-cache.json',
    'schemas/review.schema.json',
    'src/index.template.html',
    'dist/index.html',
    '.github/workflows/pages.yml'
)

foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $projectRoot $relativePath))) {
        Add-Failure "Verplicht bestand ontbreekt: $relativePath"
    }
}
if ($failures.Count -eq 0) { Write-Pass 'Verplichte bestanden aanwezig' }

$parseErrors = @()
foreach ($scriptPath in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath.FullName,
        [ref]$tokens,
        [ref]$errors
    )
    foreach ($error in @($errors)) {
        $parseErrors += "$($scriptPath.Name):$($error.Extent.StartLineNumber): $($error.Message)"
    }
}
if ($parseErrors.Count -gt 0) {
    foreach ($errorText in $parseErrors) { Add-Failure $errorText }
}
else { Write-Pass 'PowerShell-syntax geldig' }

$jsonPaths = @(
    (Join-Path $projectRoot 'config/sources.json'),
    (Join-Path $projectRoot 'data/state.json'),
    (Join-Path $projectRoot 'data/review-cache.json'),
    (Join-Path $projectRoot 'schemas/review.schema.json')
)
foreach ($jsonPath in $jsonPaths) {
    try { $null = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Add-Failure "Ongeldige JSON in $([IO.Path]::GetFileName($jsonPath)): $($_.Exception.Message)" }
}
if ($failures.Count -eq 0) { Write-Pass 'JSON-bestanden geldig' }

$configPath = Join-Path $projectRoot 'config/sources.json'
$config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
$feeds = @($config.feeds)
$duplicateUrls = @($feeds | Group-Object url | Where-Object Count -gt 1)
$duplicateNames = @($feeds | Group-Object name | Where-Object Count -gt 1)
foreach ($duplicate in $duplicateUrls) { Add-Failure "Dubbele feed-URL: $($duplicate.Name)" }
foreach ($duplicate in $duplicateNames) { Add-Failure "Dubbele bronnaam: $($duplicate.Name)" }
if ($duplicateUrls.Count -eq 0 -and $duplicateNames.Count -eq 0) {
    Write-Pass "$($feeds.Count) unieke feedbronnen"
}

$allowedCategories = @($config.categories.PSObject.Properties.Name)
$reviewPath = Join-Path $projectRoot 'data/review-cache.json'
$reviewCache = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($item in @($reviewCache.items)) {
    if (-not $item.id -or -not $item.contentHash) {
        Add-Failure 'Reviewcache bevat een item zonder id of contentHash'
        break
    }
    $invalidCategories = @($item.categories | Where-Object { $_ -notin $allowedCategories })
    if ($invalidCategories.Count -gt 0) {
        Add-Failure "Reviewitem '$($item.id)' bevat onbekende categorie: $($invalidCategories -join ', ')"
        break
    }
}
if ($failures.Count -eq 0) { Write-Pass "$(@($reviewCache.items).Count) reviewitems geldig" }

$template = Get-Content -LiteralPath (Join-Path $projectRoot 'src/index.template.html') -Raw -Encoding UTF8
$placeholderCount = ([regex]::Matches($template, '__DATA__')).Count
if ($placeholderCount -ne 1) {
    Add-Failure "Template moet exact één __DATA__-placeholder bevatten; gevonden: $placeholderCount"
}
else { Write-Pass 'Template bevat één data-placeholder' }

$published = Get-Content -LiteralPath (Join-Path $projectRoot 'dist/index.html') -Raw -Encoding UTF8
if ($published -match '__DATA__') { Add-Failure 'dist/index.html bevat nog een onvervangen placeholder' }
if ($published -notmatch '<script id="payload" type="application/json">') {
    Add-Failure 'dist/index.html bevat geen ingebedde payload'
}
if ($published -notmatch '<!doctype html>') { Add-Failure 'dist/index.html is geen volledige HTML-publicatie' }
if ($failures.Count -eq 0) { Write-Pass 'Publicatie-output compleet' }

if ($failures.Count -gt 0) {
    throw "Kwaliteitscontrole mislukt met $($failures.Count) fout(en)."
}

Write-Host "`nAlle kwaliteitscontroles geslaagd." -ForegroundColor Cyan
