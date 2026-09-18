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
    'data/notification-state.json',
    'data/review-cache.json',
    'schemas/review.schema.json',
    'src/index.template.html',
    'scripts/Send-CtrlUpdateTeamsNotification.ps1',
    'dist/index.html',
    '.github/workflows/pages.yml',
    '.github/workflows/quality.yml',
    '.github/workflows/refresh.yml',
    '.github/codex/prompts/review-items.md',
    'docs/service-health.md'
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
    (Join-Path $projectRoot 'data/notification-state.json'),
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

$bleepingComputer = @($feeds | Where-Object name -eq 'BleepingComputer - Microsoft & Windows')[0]
$incidentGroup = $config.keywords.incident
if (-not $bleepingComputer -or [string]$bleepingComputer.url -ne 'https://www.bleepingcomputer.com/feed/' -or
    [string]$bleepingComputer.tag -ne 'News' -or @($bleepingComputer.includeTerms).Count -lt 8) {
    Add-Failure 'BleepingComputer ontbreekt of heeft geen afgebakend Microsoft/Windows-bronfilter'
}
if (-not $incidentGroup -or -not [bool]$incidentGroup.isActionSignal -or
    [int]$incidentGroup.weight * [int]$config.settings.titleWeightMultiplier -lt [int]$config.settings.actionThreshold -or
    'emergency update' -notin @($incidentGroup.terms) -or 'out-of-band' -notin @($incidentGroup.terms)) {
    Add-Failure 'Kritieke incidenten bereiken niet betrouwbaar de Actie-drempel'
}
$rdsAlerts = @($config.curatedArticles | Where-Object {
    [string]$_.mode -eq 'alert' -and [string]$_.source -eq 'BleepingComputer - Microsoft & Windows'
})
if ($rdsAlerts.Count -ne 2 -or
    @($rdsAlerts | Where-Object { [string]$_.tag -ne 'News' }).Count -gt 0 -or
    @($rdsAlerts | Where-Object { [string]$_.url -match 'rds|remote-desktop-services' }).Count -ne 2) {
    Add-Failure 'De twee gecontroleerde BleepingComputer RDS-waarschuwingen ontbreken in de backfill'
}

$allowedCategories = @($config.categories.PSObject.Properties.Name)
$reviewPath = Join-Path $projectRoot 'data/review-cache.json'
$reviewCache = Get-Content -LiteralPath $reviewPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$config.agentReview.policyVersion -lt 2) {
    Add-Failure 'Agentreview mist een expliciete beleidsversie voor profielwijzigingen'
}
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
foreach ($requiredFragment in @('timezone: "Europe/Amsterdam"', '30 6 * * *', '0 14 * * *', 'teams_test:', '-TestNotification', 'openai/codex-action@v1', 'OPENAI_API_KEY', 'TEAMS_WEBHOOK_URL', 'Send-CtrlUpdateTeamsNotification.ps1', 'data/notification-state.json', 'model: gpt-5.6-terra', '-UsePreparedSnapshot', '-RequireAgentReview', 'actions/upload-pages-artifact@v5', 'actions/deploy-pages@v5', 'azure/login@v3', 'CTRL_UPDATE_ENTRA_CLIENT_ID', 'CTRL_UPDATE_ENTRA_TENANT_ID', 'ServiceHealth.Read.All')) {
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
foreach ($requiredUi in @('id="source-status"', 'id="feeds-body"', 'id="fresh-state"', 'id="search-btn"', 'id="service-health-link"', 'id="q"')) {
    if ($template -notmatch [regex]::Escape($requiredUi)) {
        Add-Failure "Centrale update- en bronstatus mist: $requiredUi"
    }
}
foreach ($unprofessionalHeader in @('Endpoint intelligence', 'Endpoint-informatie', 'internal-mark', "' · agent '")) {
    if ($template -match [regex]::Escape($unprofessionalHeader)) {
        Add-Failure "Technische of AI-achtige koptekst is teruggekeerd: $unprofessionalHeader"
    }
}
if ($template -notmatch "store\(THEME_KEY, 'light'\)" -or $template -match 'prefers-color-scheme:\s*dark') {
    Add-Failure 'Lichte modus is niet de vaste standaard voor nieuwe bezoekers'
}
if ($updater -notmatch "Urgency -eq 'critical'" -or
    $updater -notmatch "Tier -eq 'action'" -or
    $updater -notmatch "PersonalInterest -eq 'mustRead'" -or
    $updater -notmatch '(?s)Sort-Object -Property.*?\$_\.Published.*?\$_\.Score') {
    Add-Failure 'Bronitems worden niet volgens kritiek-, actie- en daarna nieuwste-eerst opgebouwd'
}
if (@([regex]::Matches($refreshWorkflow, 'uses:\s*openai/codex-action@v1')).Count -ne 8 -or
    $refreshWorkflow -notmatch 'batch_count' -or
    $refreshWorkflow -notmatch 'review-result-\*\.json') {
    Add-Failure 'Cloudreview is niet in acht begrensde, atomair samen te voegen batches voorbereid'
}
if ($template -notmatch "item\.urgency === 'critical'" -or $template -notmatch "item\.tier === 'action'" -or $template -notmatch "item\.personalInterest === 'mustRead'" -or $template -notmatch 'a\.date !== b\.date') {
    Add-Failure 'Browserweergave borgt de prioriteit- en datumsortering niet'
}
if ($template -notmatch 'Nieuwsbron' -or $updater -notmatch 'includeTerms' -or $updater -notmatch '\$feed\.tag -eq ''News''') {
    Add-Failure 'Nieuwsbronnen zijn niet herkenbaar of niet bron-specifiek gefilterd'
}
if ($updater -notmatch '\$UsePreparedSnapshot' -or
    $updater -notmatch 'prepared-publication\.json' -or
    $updater -notmatch 'Publicatiemomentopname voorbereid') {
    Add-Failure 'Review en publicatie delen geen vaste bronmomentopname'
}
if (-not $config.serviceHealth.enabled -or
    [string]$config.serviceHealth.link -ne 'https://admin.cloud.microsoft/#/servicehealth' -or
    'incident' -notin @($config.serviceHealth.includeClassifications) -or
    [string]$config.serviceHealth.privacyMode -ne 'generic' -or
    $updater -notmatch 'admin/serviceAnnouncement/issues' -or
    $updater -notmatch 'Service Health bevat tenantgebonden details' -or
    $updater -match 'impactDescription') {
    Add-Failure 'Service Health is niet minimaal, incidentgericht en privacyveilig geconfigureerd'
}
if (-not $config.messageCenter.enabled -or
    [string]$config.messageCenter.link -ne 'https://admin.cloud.microsoft/#/MessageCenter' -or
    [string]$config.messageCenter.privacyMode -ne 'derived' -or
    $updater -notmatch 'admin/serviceAnnouncement/messages' -or
    $updater -notmatch 'message-center:' -or
    $updater -match 'MessageCenter/:/messages/' -or
    $updater -notmatch 'originalTitle\s*=\s*\$\(if \(\$_\.Channel -eq ''tenant''\)' -or
    $updater -notmatch 'nativeTags\s*=\s*\$\(if \(\$_\.Kind -eq ''messagecenter''\)' -or
    $refreshWorkflow -notmatch 'CTRL_UPDATE_MESSAGE_CENTER_ENABLED' -or
    $refreshWorkflow -notmatch 'Message Center is geactiveerd, maar de Entra client- of tenantvariabele ontbreekt' -or
    $refreshWorkflow -notmatch 'ServiceMessage.Read.All') {
    Add-Failure 'Message Center is niet feature-gated, least-privilege en privacyveilig geconfigureerd'
}
foreach ($phaseTwoFragment in @('urgency-filter', 'relevance-filter', 'interest-filter', 'workflow-planned', "value: 'planned'", 'tenantRelevance', 'personalInterest', 'interestReason')) {
    if ($template -notmatch [regex]::Escape($phaseTwoFragment) -and $updater -notmatch [regex]::Escape($phaseTwoFragment)) {
        Add-Failure "Fase 2 mist verplicht oordeel of workflowveld: $phaseTwoFragment"
    }
}
if ($updater -notmatch 'reviewPolicyVersion' -or
    $updater -notmatch 'Publicatie gestopt: agentreview' -or
    $refreshWorkflow -notmatch '-RequireAgentReview') {
    Add-Failure 'Een item kan zonder actuele volledige agentreview de publicatiepoort passeren'
}
if ($template -notmatch 'searchBox\.scrollIntoView' -or $template -notmatch 'searchBox\.focus\(\)') {
    Add-Failure 'De zichtbare zoekknop activeert de bestaande zoekfunctie niet'
}
if ($failures.Count -eq 0) { Write-Pass 'Cloudrefresh bevat lokale planning, veilige Codex-action, reviewgate en actualiteitsstatus' }

$notificationScript = Join-Path $projectRoot 'scripts/Send-CtrlUpdateTeamsNotification.ps1'
$notificationSource = Get-Content -LiteralPath $notificationScript -Raw -Encoding UTF8
if ($notificationSource -notmatch "isCriticalUrgency" -or $notificationSource -notmatch "item\.urgency\s*-eq\s*'critical'") {
    Add-Failure 'Kritieke urgentie wordt niet als kritieke Teams-waarschuwing behandeld'
}
$notificationStatePath = Join-Path $projectRoot 'data/notification-state.json'
$notificationStateBefore = Get-Content -LiteralPath $notificationStatePath -Raw -Encoding UTF8
$notificationState = $notificationStateBefore | ConvertFrom-Json -AsHashtable
if ([int]$notificationState.version -ne 1 -or $notificationState.items.Count -eq 0 -or $notificationState.feeds.Count -eq 0) {
    Add-Failure 'Teams-nulmeting bevat geen geldige item- en bronstatus'
}

function Get-AdaptiveCardText {
    param($Nodes)
    $texts = [System.Collections.Generic.List[string]]::new()
    foreach ($node in @($Nodes)) {
        if ($node.text) { $texts.Add([string]$node.text) }
        if ($node.items) {
            foreach ($nested in @(Get-AdaptiveCardText -Nodes $node.items)) { $texts.Add($nested) }
        }
        if ($node.columns) {
            foreach ($column in @($node.columns)) {
                foreach ($nested in @(Get-AdaptiveCardText -Nodes $column.items)) { $texts.Add($nested) }
            }
        }
    }
    return @($texts)
}

$testPreviewText = & $notificationScript -TestNotification -PreviewOnly | Out-String
try { $testPreview = $testPreviewText | ConvertFrom-Json -AsHashtable }
catch { $testPreview = $null; Add-Failure "Teams-testpreview is geen geldige Adaptive Card: $($_.Exception.Message)" }
if ($testPreview) {
    $testCardText = @(Get-AdaptiveCardText -Nodes $testPreview.attachments[0].content.body) -join "`n"
    $testActions = @($testPreview.attachments[0].content.actions)
    if ($testCardText -notmatch 'ONTWERPVOORBEELD' -or
        $testCardText -notmatch 'Nieuwe aandachtspunten' -or
        $testCardText -notmatch 'KRITIEK\s+·\s+1' -or
        $testCardText -notmatch 'ACTIES\s+·\s+1' -or
        $testCardText -notmatch 'BRONPROBLEMEN\s+·\s+1' -or
        $testCardText -notmatch '\*\*Volgende stap:\*\*' -or
        $testCardText -notmatch 'geen beheeractie vereist' -or
        [string]$testPreview.attachments[0].content.msteams.width -ne 'Full' -or
        $testActions.Count -ne 1 -or
        [string]$testActions[0].title -ne 'Naar CTRL UPDATE') {
        Add-Failure 'Teams-testpreview bevat niet de verwachte status en acties'
    }
}

$notificationTestDirectory = Join-Path $projectRoot '.tmp/test-teams-notification'
$null = New-Item -ItemType Directory -Path $notificationTestDirectory -Force
$notificationPublishedPath = Join-Path $notificationTestDirectory 'index.html'

$payloadMatch = [regex]::Match($published, '<script id="payload" type="application/json">(?<json>[\s\S]*?)</script>')
$notificationPayload = $payloadMatch.Groups['json'].Value | ConvertFrom-Json -AsHashtable
$promotedItem = @($notificationPayload.items | Where-Object {
    $itemId = [string]$_.id
    [string]$_.tier -ne 'action' -and
        $notificationState.items.ContainsKey($itemId) -and
        [string]$notificationState.items[$itemId].tier -ne 'action'
})[0]
$failedFeed = @($notificationPayload.feeds | Where-Object Status -eq 'OK')[0]
if (-not $promotedItem -or -not $failedFeed) {
    Add-Failure 'Geen geschikt testitem of testbron voor Teams-meldingscontrole gevonden'
}
else {
    $promotedItem.tier = 'action'
    $failedFeed.Status = 'FOUT'
    $failedFeed.Detail = 'Gecontroleerde teststoring'
    $notificationJson = $notificationPayload | ConvertTo-Json -Depth 30 -Compress
    "<script id=`"payload`" type=`"application/json`">$notificationJson</script>" |
        Set-Content -LiteralPath $notificationPublishedPath -Encoding UTF8

    $previewText = & $notificationScript -PublishedPath $notificationPublishedPath -StatePath $notificationStatePath -PreviewOnly | Out-String
    try { $preview = $previewText | ConvertFrom-Json -AsHashtable }
    catch { $preview = $null; Add-Failure "Teams-preview is geen geldige Adaptive Card: $($_.Exception.Message)" }

    if ($preview) {
        $cardText = @(Get-AdaptiveCardText -Nodes $preview.attachments[0].content.body) -join "`n"
        if ([string]$preview.type -ne 'message' -or
            [string]$preview.attachments[0].contentType -ne 'application/vnd.microsoft.card.adaptive' -or
            $cardText -notmatch 'ACTIES\s+·\s+1' -or
            $cardText -notmatch 'BRONPROBLEMEN\s+·\s+1') {
            Add-Failure 'Teams-preview bevat niet uitsluitend de verwachte actie- en bronwaarschuwingen'
        }
    }

    $notificationStateAfter = Get-Content -LiteralPath $notificationStatePath -Raw -Encoding UTF8
    if ($notificationStateAfter -ne $notificationStateBefore) {
        Add-Failure 'PreviewOnly heeft de productie-nulmeting onbedoeld gewijzigd'
    }

    # Gebruik een volledig synthetisch nieuw actie-item. Dat maakt deze controle
    # deterministisch op Windows en Linux en voorkomt afhankelijkheid van welke
    # bestaande publicatie toevallig als promotiekandidaat werd gekozen.
    $criticalPayload = [ordered]@{
        items = @([ordered]@{
            id = 'ctrl-update-critical-notification-fixture'
            tier = 'action'
            title = 'Emergency update voor brede productiestoring'
            originalTitle = 'Emergency out-of-band update for widespread service disruption'
            summary = 'Beheerders moeten de noodupdate beoordelen en gecontroleerd uitrollen.'
            source = 'Gecontroleerde nieuwsbron'
            link = 'https://example.invalid/critical-warning'
            keywords = @('out-of-band')
            actionCtx = @([ordered]@{ text = 'Beoordeel de noodupdate voor getroffen systemen.' })
            dateText = '18 sep'
            keyDate = $null
            allDates = @()
        })
        feeds = @()
    }
    $criticalJson = $criticalPayload | ConvertTo-Json -Depth 30 -Compress
    "<script id=`"payload`" type=`"application/json`">$criticalJson</script>" |
        Set-Content -LiteralPath $notificationPublishedPath -Encoding UTF8
    $criticalPreviewText = & $notificationScript -PublishedPath $notificationPublishedPath -StatePath $notificationStatePath -PreviewOnly | Out-String
    try { $criticalPreview = $criticalPreviewText | ConvertFrom-Json -AsHashtable }
    catch { $criticalPreview = $null; Add-Failure "Kritieke Teams-preview is ongeldig: $($_.Exception.Message)" }
    if ($criticalPreview) {
        $criticalCardText = @(Get-AdaptiveCardText -Nodes $criticalPreview.attachments[0].content.body) -join "`n"
        $criticalActions = @($criticalPreview.attachments[0].content.actions)
        if (@([regex]::Matches($criticalCardText, 'Kritieke waarschuwing', 'IgnoreCase')).Count -ne 1 -or
            $criticalCardText -notmatch '\*\*Volgende stap:\*\*' -or
            $criticalActions.Count -ne 2 -or
            [string]$criticalActions[0].title -ne 'Bron bekijken') {
            Add-Failure 'Incidentactie wordt niet als kritieke Teams-waarschuwing weergegeven'
        }
    }

    # Een kritisch Service Health-incident is ernstig, maar zonder aangetoonde
    # klantactie geen Actie-item. Het moet desondanks als kritieke waarschuwing
    # kunnen melden.
    $criticalWatchPayload = [ordered]@{
        items = @([ordered]@{
            id = 'ctrl-update-critical-watch-fixture'
            tier = 'watch'; urgency = 'critical'; kind = 'servicehealth'
            title = 'Kritiek Microsoft 365-incident'
            originalTitle = 'Critical Microsoft 365 incident'
            summary = 'Microsoft meldt een kritieke onderbreking in de referentietenant.'
            source = 'Microsoft 365 Service Health'
            link = 'https://admin.cloud.microsoft/#/servicehealth'
            keywords = @('service health'); actionCtx = @()
            dateText = '18 sep'; keyDate = $null; allDates = @()
        })
        feeds = @()
    }
    $criticalWatchJson = $criticalWatchPayload | ConvertTo-Json -Depth 30 -Compress
    "<script id=`"payload`" type=`"application/json`">$criticalWatchJson</script>" |
        Set-Content -LiteralPath $notificationPublishedPath -Encoding UTF8
    $criticalWatchPreviewText = & $notificationScript -PublishedPath $notificationPublishedPath -StatePath $notificationStatePath -PreviewOnly | Out-String
    try { $criticalWatchPreview = $criticalWatchPreviewText | ConvertFrom-Json -AsHashtable }
    catch { $criticalWatchPreview = $null; Add-Failure "Kritieke Let op-preview is ongeldig: $($_.Exception.Message)" }
    if ($criticalWatchPreview) {
        $criticalWatchText = @(Get-AdaptiveCardText -Nodes $criticalWatchPreview.attachments[0].content.body) -join "`n"
        if ($criticalWatchText -notmatch 'Kritieke waarschuwing' -or $criticalWatchText -match 'Actie vereist') {
            Add-Failure 'Kritiek incident zonder beheeractie wordt niet afzonderlijk en correct gemeld'
        }
    }

    $multiActionItems = @(1..3 | ForEach-Object {
        [ordered]@{
            id = "ctrl-update-compact-action-fixture-$_"
            tier = 'action'
            title = "Lifecycle-actie $_"
            originalTitle = "Lifecycle action $_"
            summary = "Deze lange samenvatting $_ hoort niet op een compacte kaart met meerdere acties."
            source = 'Gecontroleerde bron'
            link = "https://example.invalid/action-$_"
            keywords = @('failure')
            actionCtx = @([ordered]@{ text = "Plan lifecycle-actie $_ voor de relevante beheergroep." })
            dateText = '18 sep'
            keyDate = $null
            allDates = @()
        }
    })
    $multiActionJson = [ordered]@{ items = $multiActionItems; feeds = @() } | ConvertTo-Json -Depth 30 -Compress
    "<script id=`"payload`" type=`"application/json`">$multiActionJson</script>" |
        Set-Content -LiteralPath $notificationPublishedPath -Encoding UTF8
    $multiActionPreviewText = & $notificationScript -PublishedPath $notificationPublishedPath -StatePath $notificationStatePath -PreviewOnly | Out-String
    try { $multiActionPreview = $multiActionPreviewText | ConvertFrom-Json -AsHashtable }
    catch { $multiActionPreview = $null; Add-Failure "Compacte Teams-preview is ongeldig: $($_.Exception.Message)" }
    if ($multiActionPreview) {
        $multiActionCardText = @(Get-AdaptiveCardText -Nodes $multiActionPreview.attachments[0].content.body) -join "`n"
        if ($multiActionCardText -notmatch 'ACTIES\s+·\s+3' -or
            $multiActionCardText -match 'Kritieke waarschuwing' -or
            $multiActionCardText -notmatch '\*\*Volgende stap:\*\*' -or
            $multiActionCardText -match 'hoort niet op een compacte kaart') {
            Add-Failure 'Kaart met meerdere gewone acties is niet compact of wordt onterecht kritiek genoemd'
        }
    }
}
if ($failures.Count -eq 0) { Write-Pass 'Teams-meldingen zijn actiegericht, kaartgeldig en zonder eerste spamgolf' }

$testDirectory = Join-Path $projectRoot '.tmp/test-review-pipeline'
$null = New-Item -ItemType Directory -Path $testDirectory -Force
$testInputPath = Join-Path $testDirectory 'input.json'
$testCachePath = Join-Path $testDirectory 'cache.json'
$testPendingPath = Join-Path $testDirectory 'pending.json'
$testResultPath = Join-Path $testDirectory 'result.json'
$testBatchDirectory = Join-Path $testDirectory 'batches'

function New-TestReview {
    param([string] $Id, [string] $Hash)
    [PSCustomObject]@{
        id = $Id; contentHash = $Hash; reviewPolicyVersion = 2
        titleNl = "Nederlandse titel $Id"; summaryNl = 'Nederlandse samenvatting.'; whyNl = @()
        titleEn = "English title $Id"; summaryEn = 'English summary.'; whyEn = @()
        categories = @($allowedCategories[0]); kind = 'nieuws'; tier = 'info'; confidence = 0.9
        urgency = 'normal'; tenantRelevance = 'unknown'
        tenantReasonNl = 'Tenantimpact niet bevestigd.'; tenantReasonEn = 'Tenant impact is not confirmed.'
        personalInterest = 'relevant'; interestReasonNl = 'Bruikbaar voor dagelijks beheer.'; interestReasonEn = 'Useful for daily administration.'
        reasonNl = 'Geen concrete beheeractie.'; reasonEn = 'No concrete administrative action.'
    }
}

try {
    [PSCustomObject]@{ items = @(
        [PSCustomObject]@{ id = 'fixture-1'; contentHash = 'hash-1'; reviewPolicyVersion = 2 },
        [PSCustomObject]@{ id = 'fixture-2'; contentHash = 'hash-2'; reviewPolicyVersion = 2 }
    ) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testInputPath -Encoding UTF8
    [PSCustomObject]@{ generated = '2026-01-01T00:00:00Z'; items = @(
        (New-TestReview -Id 'fixture-1' -Hash 'hash-1')
    ) } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testCachePath -Encoding UTF8

    $pendingCount = & (Join-Path $PSScriptRoot 'New-CtrlUpdateReviewBatch.ps1') `
        -InputPath $testInputPath -CachePath $testCachePath -OutputPath $testPendingPath `
        -BatchDirectory $testBatchDirectory -BatchSize 1
    if ($pendingCount -ne 1) { Add-Failure "Reviewbatchfixture verwachtte 1 item maar vond $pendingCount" }
    elseif (@(Get-ChildItem -LiteralPath $testBatchDirectory -Filter 'batch-*.json' -File).Count -ne 1) {
        Add-Failure 'Reviewbatchfixture is niet in begrensde agentbatch opgesplitst'
    }

    # Simuleert een model dat pipeline-metadata verkeerd terugkopieert. De merge
    # moet hash én beleidsversie herstellen zonder onbekende ids toe te laten.
    $fixtureTwoResult = New-TestReview -Id 'fixture-2' -Hash '0'
    $fixtureTwoResult.reviewPolicyVersion = 1
    [PSCustomObject]@{ items = @($fixtureTwoResult) } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $testResultPath -Encoding UTF8

    & (Join-Path $PSScriptRoot 'Merge-CtrlUpdateReview.ps1') `
        -InputPath $testInputPath -PendingPath $testPendingPath -ResultPath $testResultPath `
        -CachePath $testCachePath -ConfigPath $configPath

    $mergedFixture = Get-Content -LiteralPath $testCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (@($mergedFixture.items).Count -ne 2) { Add-Failure 'Reviewmergefixture bevat niet exact twee items' }
    elseif ([string]@($mergedFixture.items | Where-Object id -eq 'fixture-2')[0].contentHash -ne 'hash-2') {
        Add-Failure 'Reviewmerge herstelt pipeline-metadata niet deterministisch'
    }
    elseif ([int]@($mergedFixture.items | Where-Object id -eq 'fixture-2')[0].reviewPolicyVersion -ne 2) {
        Add-Failure 'Reviewmerge herstelt de reviewbeleidsversie niet deterministisch'
    }
    elseif ($failures.Count -eq 0) { Write-Pass 'Cloudreviewselectie en atomaire cachemerge geldig' }
}
catch {
    Add-Failure "Cloudreviewpijplijntest mislukt: $($_.Exception.Message)"
}
finally {
    foreach ($path in @($testInputPath, $testCachePath, $testPendingPath, $testResultPath)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $testBatchDirectory) {
        Get-ChildItem -LiteralPath $testBatchDirectory -Filter 'batch-*.json' -File |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $testBatchDirectory -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $testDirectory -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    throw "Kwaliteitscontrole mislukt met $($failures.Count) fout(en)."
}

Write-Host "`nAlle kwaliteitscontroles geslaagd." -ForegroundColor Cyan
