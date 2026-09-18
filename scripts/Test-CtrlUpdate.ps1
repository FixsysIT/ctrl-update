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
    '.github/workflows/pages.yml',
    '.github/workflows/quality.yml',
    '.github/workflows/refresh.yml',
    '.github/codex/prompts/review-items.md'
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
$updater = Get-Content -LiteralPath (Join-Path $projectRoot 'scripts/Update-CtrlUpdate.ps1') -Raw -Encoding UTF8
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

$refreshWorkflow = Get-Content -LiteralPath (Join-Path $projectRoot '.github/workflows/refresh.yml') -Raw -Encoding UTF8
foreach ($requiredFragment in @('timezone: "Europe/Amsterdam"', '30 6 * * *', '0 14 * * *', 'openai/codex-action@v1', 'OPENAI_API_KEY', 'model: gpt-5.6-terra', '-RequireAgentReview', 'actions/upload-pages-artifact@v5', 'actions/deploy-pages@v5')) {
    if ($refreshWorkflow -notmatch [regex]::Escape($requiredFragment)) {
        Add-Failure "Refresh-workflow mist verplichte configuratie: $requiredFragment"
    }
}
if ($template -notmatch 'staleAfterHours' -or $template -notmatch 'fresh-state-value') {
    Add-Failure 'Template mist zichtbare actualiteitsbewaking en de laatste succesvolle update'
}
if ($template -notmatch "f.Status === 'OVERGESLAGEN'") {
    Add-Failure 'Bewust overgeslagen bronnen worden ten onrechte als bronstoring geteld'
}
foreach ($removedUi in @('id="density"', 'id="help-btn"', 'id="metric-health"', 'id="status"', 'id="src"', 'id="fresh-last"', 'id="fresh-next"', 'CAT_VISIBLE')) {
    if ($template -match [regex]::Escape($removedUi)) {
        Add-Failure "Verwijderde of dubbele UI is teruggekeerd: $removedUi"
    }
}
foreach ($requiredUi in @('id="source-status"', 'id="feeds-body"', 'id="fresh-state"')) {
    if ($template -notmatch [regex]::Escape($requiredUi)) {
        Add-Failure "Centrale update- en bronstatus mist: $requiredUi"
    }
}
if ($updater -notmatch '\$priorityRank\s*=\s*@\{\s*action\s*=\s*0;\s*watch\s*=\s*1;\s*info\s*=\s*1\s*\}' -or
    $updater -notmatch '(?s)\$priorityRank\[\$_\.Tier\].*?\$_\.Published.*?\$_\.Score') {
    Add-Failure 'Bronitems worden niet volgens actie-eerst, daarna nieuwste-eerst opgebouwd'
}
if ($template -notmatch "a\.tier === 'action'" -or $template -notmatch 'a\.date !== b\.date') {
    Add-Failure 'Browserweergave borgt de prioriteit- en datumsortering niet'
}
if ($failures.Count -eq 0) { Write-Pass 'Cloudrefresh bevat lokale planning, veilige Codex-action, reviewgate en actualiteitsstatus' }

$testDirectory = Join-Path $projectRoot '.tmp/test-review-pipeline'
$null = New-Item -ItemType Directory -Path $testDirectory -Force
$testInputPath = Join-Path $testDirectory 'input.json'
$testCachePath = Join-Path $testDirectory 'cache.json'
$testPendingPath = Join-Path $testDirectory 'pending.json'
$testResultPath = Join-Path $testDirectory 'result.json'

function New-TestReview {
    param([string] $Id, [string] $Hash)
    [PSCustomObject]@{
        id = $Id; contentHash = $Hash
        titleNl = "Nederlandse titel $Id"; summaryNl = 'Nederlandse samenvatting.'; whyNl = @()
        titleEn = "English title $Id"; summaryEn = 'English summary.'; whyEn = @()
        categories = @($allowedCategories[0]); kind = 'nieuws'; tier = 'info'; confidence = 0.9
        reasonNl = 'Geen concrete beheeractie.'; reasonEn = 'No concrete administrative action.'
    }
}

try {
    [PSCustomObject]@{ items = @(
        [PSCustomObject]@{ id = 'fixture-1'; contentHash = 'hash-1' },
        [PSCustomObject]@{ id = 'fixture-2'; contentHash = 'hash-2' }
    ) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testInputPath -Encoding UTF8
    [PSCustomObject]@{ generated = '2026-01-01T00:00:00Z'; items = @(
        (New-TestReview -Id 'fixture-1' -Hash 'hash-1')
    ) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testCachePath -Encoding UTF8

    $pendingCount = & (Join-Path $PSScriptRoot 'New-CtrlUpdateReviewBatch.ps1') `
        -InputPath $testInputPath -CachePath $testCachePath -OutputPath $testPendingPath
    if ($pendingCount -ne 1) { Add-Failure "Reviewbatchfixture verwachtte 1 item maar vond $pendingCount" }

    [PSCustomObject]@{ items = @(
        (New-TestReview -Id 'fixture-2' -Hash 'hash-2')
    ) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testResultPath -Encoding UTF8

    & (Join-Path $PSScriptRoot 'Merge-CtrlUpdateReview.ps1') `
        -InputPath $testInputPath -PendingPath $testPendingPath -ResultPath $testResultPath `
        -CachePath $testCachePath -ConfigPath $configPath

    $mergedFixture = Get-Content -LiteralPath $testCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($mergedFixture.items).Count -ne 2) { Add-Failure 'Reviewmergefixture bevat niet exact twee items' }
    elseif ($failures.Count -eq 0) { Write-Pass 'Cloudreviewselectie en atomaire cachemerge geldig' }
}
catch {
    Add-Failure "Cloudreviewpijplijntest mislukt: $($_.Exception.Message)"
}
finally {
    foreach ($path in @($testInputPath, $testCachePath, $testPendingPath, $testResultPath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testDirectory -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    throw "Kwaliteitscontrole mislukt met $($failures.Count) fout(en)."
}

Write-Host "`nAlle kwaliteitscontroles geslaagd." -ForegroundColor Cyan
