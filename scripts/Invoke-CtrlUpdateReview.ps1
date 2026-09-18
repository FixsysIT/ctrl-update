<#
.SYNOPSIS
    Laat Codex nieuwsitems inhoudelijk beoordelen en in helder Nederlands herschrijven.

.DESCRIPTION
    Gebruikt de lokaal aangemelde Codex CLI in niet-interactieve modus. Reviews
    worden op inhoudshash gecachet: ongewijzigde artikelen kosten bij een volgende
    run geen nieuwe modelaanroep. De uitvoer wordt met een JSON-schema afgedwongen
    en daarna nog lokaal gevalideerd.
#>
[CmdletBinding()]
param(
    [string] $InputPath  = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/review-input.json'),
    [string] $OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/review-cache.json'),
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/sources.json'),
    [string] $SchemaPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/review.schema.json'),
    [int]    $BatchSize
)

$ErrorActionPreference = 'Stop'

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
}

if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    throw 'Codex CLI niet gevonden. Installeer Codex of gebruik Update-CtrlUpdate.ps1 -SkipAgentReview.'
}

$inputData = Get-Content -LiteralPath $InputPath -Raw -Encoding UTF8 | ConvertFrom-Json
$config    = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $BatchSize) { $BatchSize = [int]$config.agentReview.batchSize }
if ($BatchSize -lt 1) { $BatchSize = 10 }

$allowedCategories = @($config.categories.PSObject.Properties.Name)
$wanted = @($inputData.items)
$cacheById = @{}

if (Test-Path -LiteralPath $OutputPath) {
    try {
        $cached = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($item in @($cached.items)) {
            if ($item.id) { $cacheById[[string]$item.id] = $item }
        }
    }
    catch {
        Write-Warning "Bestaande agentreview is onleesbaar en wordt opnieuw opgebouwd: $($_.Exception.Message)"
    }
}

$resultById = @{}
$pending = [System.Collections.Generic.List[object]]::new()
foreach ($item in $wanted) {
    $id = [string]$item.id
    if ($cacheById.ContainsKey($id) -and
        [string]$cacheById[$id].contentHash -eq [string]$item.contentHash -and
        [int]$cacheById[$id].reviewPolicyVersion -eq [int]$item.reviewPolicyVersion -and
        -not [string]::IsNullOrWhiteSpace([string]$cacheById[$id].titleEn) -and
        -not [string]::IsNullOrWhiteSpace([string]$cacheById[$id].summaryEn) -and
        -not [string]::IsNullOrWhiteSpace([string]$cacheById[$id].reasonEn) -and
        [string]$cacheById[$id].personalInterest -in @('mustRead', 'relevant', 'background', 'low') -and
        -not [string]::IsNullOrWhiteSpace([string]$cacheById[$id].interestReasonNl) -and
        -not [string]::IsNullOrWhiteSpace([string]$cacheById[$id].interestReasonEn)) {
        $resultById[$id] = $cacheById[$id]
    }
    else {
        $pending.Add($item)
    }
}

Write-Host "Agentreview: $($resultById.Count) uit cache, $($pending.Count) te beoordelen." -ForegroundColor Cyan

for ($offset = 0; $offset -lt $pending.Count; $offset += $BatchSize) {
    $last = [Math]::Min($offset + $BatchSize - 1, $pending.Count - 1)
    $batch = @($pending[$offset..$last])
    $number = [Math]::Floor($offset / $BatchSize) + 1
    $totalBatches = [Math]::Ceiling($pending.Count / [double]$BatchSize)
    Write-Host "  Batch $number van $totalBatches ($($batch.Count) items)"

    $itemsJson = $batch | ConvertTo-Json -Depth 10 -Compress
    $categoryText = $allowedCategories -join ', '
    $prompt = @"
Je bent de eindredacteur van een Nederlands dashboard voor Intune- en Entra-beheerders.
Beoordeel ALLE aangeleverde items op inhoud. Gebruik uitsluitend de meegeleverde titel en brontekst; verzin geen feiten.

Lever voor elk item exact een object terug met hetzelfde id, contentHash en reviewPolicyVersion.
- titleNl: natuurlijke, zakelijke Nederlandse titel. Productnamen, feature-namen en Message Center-id's niet vertalen.
- summaryNl: maximaal twee korte Nederlandse zinnen die zeggen wat er werkelijk verandert of wordt uitgelegd.
- whyNl: nul tot drie korte Nederlandse punten. Alleen concrete impact, vereiste beheeractie en harde datum. Geen reclame of algemene intro.
- titleEn, summaryEn en whyEn: dezelfde inhoud in natuurlijk, zakelijk Engels; vertaal product- en feature-namen niet.
- categories: maximaal drie uit deze vaste lijst: $categoryText
- kind: wijziging, nieuws, analyse, handleiding of naslag.
- tier: action alleen bij een concrete beheeractie, verplichte migratie, deadline, retirement of operationeel probleem; watch bij relevante ontwikkeling die aandacht verdient; info bij nieuws, analyse, handleiding of naslag zonder concrete actie.
- urgency: critical alleen bij actuele brede uitval, actief misbruik, noodupdate of onmiddellijke harde deadline; high bij grote impact of nabije verplichte wijziging; normal bij reguliere wijzigingen en relevante statusinformatie; anders low.
- tenantRelevance: confirmed wanneer channel tenant is; likely bij een openbare bron die duidelijk een beheerd Microsoft-, endpoint-, identity- of securityonderwerp raakt; unknown wanneer toepasbaarheid niet bewezen is; notApplicable alleen met expliciete evidence.
- tenantReasonNl en tenantReasonEn: een korte toelichting op de tenantrelevantie. Confirmed betekent bevestigd in de referentietenant, niet bewezen impact voor iedere klant.
- personalInterest: mustRead wanneer de eigenaar dit beslist moet zien voor Intune, Entra, endpointbeheer, Microsoft 365-beheer, security, actuele storingen, lifecycle, licenties of klantcommunicatie; relevant voor waarschijnlijk bruikbare veranderingen, praktische kennis en handleidingen; background voor nuttige context zonder directe toepassing; low alleen voor marketing, herhaling of nauwelijks aansluitende inhoud.
- interestReasonNl en interestReasonEn: een concrete zin waarom dit voor hem deze informatiewaarde heeft.
- confidence: 0 tot 1, lager als de brontekst onvoldoende bewijs bevat.
- reasonNl: een korte Nederlandse toelichting op de gekozen tier.
- reasonEn: dezelfde korte toelichting in het Engels.

De regelscore en voorgestelde waarden zijn aanwijzingen, geen feiten. Jij bepaalt voor ieder item zelfstandig soort, categorie, actieerbaarheid, urgentie, tenantrelevantie en persoonlijke informatiewaarde. Corrigeer foutpositieven. Een hoge trefwoordscore maakt naslag niet automatisch actie. Service Health kan kritisch zijn zonder concrete actie. Message Center is tenantbevestigd maar kan informatief, te volgen of actiegericht zijn.
Schrijf de *Nl-velden volledig in het Nederlands en de *En-velden volledig in het Engels, helder en zonder Markdown. Geef alleen JSON volgens het schema.

ITEMS:
$itemsJson
"@

    $batchPath = Join-Path ([IO.Path]::GetTempPath()) ("ctrl-update-review-{0}-{1}.json" -f $PID, $number)
    try {
        $log = $prompt | & codex exec --ephemeral --sandbox read-only --output-schema $SchemaPath -o $batchPath - 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Codex stopte met code $LASTEXITCODE. $($log -join ' ')"
        }

        $response = Get-Content -LiteralPath $batchPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $expected = @{}
        foreach ($item in $batch) { $expected[[string]$item.id] = [string]$item.contentHash }

        foreach ($review in @($response.items)) {
            $id = [string]$review.id
            if (-not $expected.ContainsKey($id)) { continue }
            if ([string]$review.contentHash -ne $expected[$id]) { continue }
            $validCategories = @($review.categories | Where-Object { $_ -in $allowedCategories } | Select-Object -Unique -First 3)
            if ($validCategories.Count -eq 0) { continue }

            $review.categories = $validCategories
            $resultById[$id] = $review
        }
    }
    finally {
        Remove-Item -LiteralPath $batchPath -Force -ErrorAction SilentlyContinue
    }
}

$ordered = @($wanted | ForEach-Object {
    if ($resultById.ContainsKey([string]$_.id)) { $resultById[[string]$_.id] }
})

$result = [PSCustomObject]@{
    generated = (Get-Date).ToUniversalTime().ToString('o')
    items = $ordered
}

$temporary = "$OutputPath.tmp"
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporary -Encoding UTF8
$null = Get-Content -LiteralPath $temporary -Raw -Encoding UTF8 | ConvertFrom-Json
Move-Item -LiteralPath $temporary -Destination $OutputPath -Force

Write-Host "Agentreview opgeslagen: $($ordered.Count) items." -ForegroundColor Green
