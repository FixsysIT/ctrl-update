<#
.SYNOPSIS
    Stuurt alleen nieuwe handelingswaardige CTRL UPDATE-signalen naar Teams.

.DESCRIPTION
    Vergelijkt de gepubliceerde payload met een compacte, versiebeheerbare nulmeting.
    Alleen nieuwe of gepromoveerde Actie-items, gewijzigde actiedatums en nieuwe
    bronstoringen worden gemeld. Een succesvolle verzending werkt de nulmeting bij.
    Een mislukte verzending laat de vorige nulmeting intact, zodat de melding bij de
    volgende run opnieuw kan worden geprobeerd.
#>
[CmdletBinding(DefaultParameterSetName = 'Content')]
param(
    [Parameter(ParameterSetName = 'Content')]
    [string] $PublishedPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist/index.html'),

    [Parameter(ParameterSetName = 'Content')]
    [string] $StatePath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/notification-state.json'),

    [Parameter(ParameterSetName = 'Content')]
    [switch] $InitializeOnly,

    [Parameter(Mandatory, ParameterSetName = 'Failure')]
    [string] $FailureMessage,

    [Parameter(Mandatory, ParameterSetName = 'Test')]
    [switch] $TestNotification,

    [string] $RunUrl,

    [switch] $PreviewOnly,
    [string] $WebhookUrl = $env:TEAMS_WEBHOOK_URL,
    [string] $SiteUrl = 'https://news.intunetools.com/'
)

$ErrorActionPreference = 'Stop'

function New-TextBlock {
    param(
        [Parameter(Mandatory)] [string] $Text,
        [string] $Size,
        [string] $Weight,
        [string] $Color,
        [bool] $Wrap = $true,
        [string] $Spacing,
        [switch] $Subtle
    )

    $block = [ordered]@{ type = 'TextBlock'; text = $Text; wrap = $Wrap }
    if ($Size)    { $block.size = $Size }
    if ($Weight)  { $block.weight = $Weight }
    if ($Color)   { $block.color = $Color }
    if ($Spacing) { $block.spacing = $Spacing }
    if ($Subtle)  { $block.isSubtle = $true }
    return $block
}

function New-FactSet {
    param([Parameter(Mandatory)] [System.Collections.IEnumerable] $Facts)
    return [ordered]@{ type = 'FactSet'; spacing = 'Small'; facts = @($Facts) }
}

function Get-DisplaySource {
    param([string] $Source)
    if ($Source -eq 'BleepingComputer - Microsoft & Windows') { return 'BleepingComputer' }
    return $Source
}

function New-TeamsEnvelope {
    param(
        [Parameter(Mandatory)] [System.Collections.IEnumerable] $Body,
        [Parameter(Mandatory)] [System.Collections.IEnumerable] $Actions
    )

    return [ordered]@{
        type = 'message'
        attachments = @(
            [ordered]@{
                contentType = 'application/vnd.microsoft.card.adaptive'
                contentUrl  = $null
                content     = [ordered]@{
                    '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                    type      = 'AdaptiveCard'
                    version   = '1.4'
                    msteams   = [ordered]@{ width = 'Full' }
                    body      = @($Body)
                    actions   = @($Actions)
                }
            }
        )
    }
}

function Send-TeamsEnvelope {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Envelope,
        [Parameter(Mandatory)] [string] $Url
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw 'GitHub-secret TEAMS_WEBHOOK_URL ontbreekt.'
    }

    $json = $Envelope | ConvertTo-Json -Depth 20 -Compress
    $lastError = $null
    foreach ($attempt in 1..3) {
        try {
            $response = Invoke-WebRequest -Method Post -Uri $Url -ContentType 'application/json' -Body $json
            if ([int]$response.StatusCode -notin 200, 201, 202) {
                throw "Teams-webhook retourneerde HTTP $([int]$response.StatusCode)."
            }
            Write-Host "Teams-webhook accepteerde de Adaptive Card (HTTP $([int]$response.StatusCode))." -ForegroundColor Green
            return
        }
        catch {
            $lastError = $_
            if ($attempt -lt 3) { Start-Sleep -Seconds ([math]::Pow(2, $attempt)) }
        }
    }
    throw "Teams-melding mislukt na drie pogingen: $($lastError.Exception.Message)"
}

function Get-PublishedPayload {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Publicatie ontbreekt: $Path" }
    $html = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match($html, '<script id="payload" type="application/json">(?<json>[\s\S]*?)</script>')
    if (-not $match.Success) { throw 'De gepubliceerde payload kon niet worden gelezen.' }
    return $match.Groups['json'].Value | ConvertFrom-Json -AsHashtable
}

function Get-NotificationState {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
}

function New-NotificationState {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Payload)

    $items = [ordered]@{}
    foreach ($item in @($Payload.items)) {
        $dateIso = $null
        $dateKind = $null
        $hardDates = @()
        if ($item.keyDate) {
            $dateIso = [string]$item.keyDate.iso
            $dateKind = [string]$item.keyDate.kind
        }
        foreach ($date in @($item.allDates)) {
            if ([string]$date.kind -in 'deadline', 'retirement', 'start') {
                $hardDates += "$([string]$date.kind):$([string]$date.iso)"
            }
        }
        $items[[string]$item.id] = [ordered]@{
            tier     = [string]$item.tier
            dateIso  = $dateIso
            dateKind = $dateKind
            hardDates = @($hardDates | Sort-Object -Unique)
        }
    }

    $feeds = [ordered]@{}
    foreach ($feed in @($Payload.feeds)) {
        $feeds[[string]$feed.Source] = [string]$feed.Status
    }

    return [ordered]@{
        version   = 1
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o')
        items     = $items
        feeds     = $feeds
    }
}

function Save-NotificationState {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $State,
        [Parameter(Mandatory)] [string] $Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $temporaryPath = "$Path.tmp"
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-ShortText {
    param([string] $Text, [int] $Length = 220)
    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -le $Length) { return $Text }
    return $Text.Substring(0, $Length - 1).TrimEnd() + '…'
}

if ($PSCmdlet.ParameterSetName -eq 'Test') {
    $sampleItems = @(
        New-TextBlock -Text 'Microsoft brengt noodupdates uit voor RDS-storingen' -Weight Bolder -Size Medium
        New-FactSet -Facts @(
            [ordered]@{ title = 'Bron'; value = 'BleepingComputer' }
            [ordered]@{ title = 'Gepubliceerd'; value = '18 sep' }
        )
        New-TextBlock -Text 'Microsoft heeft out-of-band-updates uitgebracht voor getroffen Remote Desktop Services-omgevingen.' -Spacing Small
        New-TextBlock -Text 'Te beoordelen' -Weight Bolder -Color Accent -Spacing Medium
        New-TextBlock -Text '• Beoordeel de noodupdate voor getroffen RDS-systemen.' -Spacing Small
    )
    $body = @(
        New-TextBlock -Text 'CTRL UPDATE · ONTWERPVOORBEELD' -Weight Bolder -Size Small -Color Accent
        New-TextBlock -Text 'Kritieke waarschuwing' -Weight Bolder -Color Attention -Size Large -Spacing Small
        [ordered]@{ type = 'Container'; spacing = 'Medium'; items = $sampleItems }
        New-TextBlock -Text 'Testbericht · geen beheeractie vereist' -Subtle -Spacing Medium
    )
    $actions = @(
        [ordered]@{ type = 'Action.OpenUrl'; title = 'CTRL UPDATE openen'; url = $SiteUrl }
    )
    if ($RunUrl) {
        $actions += [ordered]@{ type = 'Action.OpenUrl'; title = 'GitHub-run bekijken'; url = $RunUrl }
    }
    $testEnvelope = New-TeamsEnvelope -Body $body -Actions $actions
    if ($PreviewOnly) {
        $testEnvelope | ConvertTo-Json -Depth 20
        return
    }
    Send-TeamsEnvelope -Envelope $testEnvelope -Url $WebhookUrl
    return
}

if ($PSCmdlet.ParameterSetName -eq 'Failure') {
    $body = @(
        New-TextBlock -Text 'CTRL UPDATE' -Weight Bolder -Size Small -Color Accent
        New-TextBlock -Text 'Automatische refresh mislukt' -Weight Bolder -Color Attention -Size Large -Spacing Small
        New-TextBlock -Text $FailureMessage -Spacing Small
        New-TextBlock -Text 'De vorige geslaagde versie blijft online; er is niets onvolledig gepubliceerd.' -Subtle -Spacing Medium
    )
    $actions = @([ordered]@{ type = 'Action.OpenUrl'; title = 'GitHub-run bekijken'; url = $(if ($RunUrl) { $RunUrl } else { $SiteUrl }) })
    $failureEnvelope = New-TeamsEnvelope -Body $body -Actions $actions
    if ($PreviewOnly) {
        $failureEnvelope | ConvertTo-Json -Depth 20
        return
    }
    Send-TeamsEnvelope -Envelope $failureEnvelope -Url $WebhookUrl
    return
}

$payload = Get-PublishedPayload -Path $PublishedPath
$nextState = New-NotificationState -Payload $payload
$previousState = Get-NotificationState -Path $StatePath

if (-not $previousState -or $InitializeOnly) {
    if (-not $PreviewOnly) { Save-NotificationState -State $nextState -Path $StatePath }
    Write-Host 'Teams-nulmeting vastgelegd; bestaande items veroorzaken geen meldingen.' -ForegroundColor Green
    return
}

$events = [System.Collections.Generic.List[object]]::new()
$previousItems = if ($previousState.items) { $previousState.items } else { @{} }
$previousFeeds = if ($previousState.feeds) { $previousState.feeds } else { @{} }
$criticalIncidentPatterns = @(
    '(?i)\bemergency\b.{0,35}\bupdates?\b',
    '(?i)\bout-of-band\b',
    '(?i)\bzero-day\b',
    '(?i)\bactively exploited\b',
    '(?i)\bwidespread\b',
    '(?i)\bservice disruption\b',
    '(?i)\bmajor outage\b',
    '(?i)\bunresponsive (servers?|service|systems?)\b'
)

foreach ($item in @($payload.items)) {
    if ([string]$item.tier -ne 'action') { continue }

    $id = [string]$item.id
    $previous = if ($previousItems.ContainsKey($id)) { $previousItems[$id] } else { $null }
    $currentDate = if ($item.keyDate) { [string]$item.keyDate.iso } else { '' }
    $currentKind = if ($item.keyDate) { [string]$item.keyDate.kind } else { '' }
    $currentHardDates = @($item.allDates |
        Where-Object { [string]$_.kind -in 'deadline', 'retirement', 'start' } |
        ForEach-Object { "$([string]$_.kind):$([string]$_.iso)" } |
        Sort-Object -Unique)
    $previousHardDates = @($previous.hardDates | ForEach-Object { [string]$_ } | Sort-Object -Unique)

    # Alleen sterke signalen in de zichtbare titel/samenvatting maken een Actie
    # kritiek. Losse trefwoorden diep in een artikel mogen een gewone lifecycle-
    # actie of beperkte storing niet onterecht opschalen.
    $criticalText = "$([string]$item.originalTitle) $([string]$item.title) $([string]$item.summary)"
    $isCriticalIncident = @($criticalIncidentPatterns | Where-Object { $criticalText -match $_ }).Count -gt 0

    $eventType = $null
    if (-not $previous) { $eventType = $(if ($isCriticalIncident) { 'Kritieke waarschuwing' } else { 'Nieuwe actie' }) }
    elseif ([string]$previous.tier -ne 'action') { $eventType = $(if ($isCriticalIncident) { 'Kritieke waarschuwing' } else { 'Naar Actie gepromoveerd' }) }
    elseif ([string]$previous.dateIso -ne $currentDate -or
            [string]$previous.dateKind -ne $currentKind -or
            ($previousHardDates -join '|') -ne ($currentHardDates -join '|')) {
        $eventType = 'Actiedatum gewijzigd'
    }

    if ($eventType) {
        $events.Add([ordered]@{
            kind    = 'action'
            label   = $eventType
            title   = [string]$item.title
            summary = [string]$item.summary
            source  = [string]$item.source
            date    = $(if ($item.keyDate) { [string]$item.keyDate.text } else { $null })
            published = [string]$item.dateText
            link    = [string]$item.link
            why     = @($item.actionCtx | ForEach-Object {
                if ($_ -is [string]) { [string]$_ } else { [string]$_.text }
            } | Where-Object { $_ } | Select-Object -First 2)
            critical = $isCriticalIncident
        })
    }
}

foreach ($feed in @($payload.feeds)) {
    if ([string]$feed.Status -ne 'FOUT') { continue }
    $source = [string]$feed.Source
    $oldStatus = if ($previousFeeds.ContainsKey($source)) { [string]$previousFeeds[$source] } else { '' }
    if ($oldStatus -ne 'FOUT') {
        $events.Add([ordered]@{
            kind    = 'source'
            label   = 'Nieuwe bronstoring'
            title   = $source
            summary = [string]$feed.Detail
            source  = $source
            date    = $null
            published = $null
            link    = $SiteUrl
            why     = @()
            critical = $false
        })
    }
}

if ($events.Count -eq 0) {
    if (-not $PreviewOnly) { Save-NotificationState -State $nextState -Path $StatePath }
    Write-Host 'Geen nieuwe Actie-signalen, gewijzigde actiedatums of bronstoringen; Teams blijft stil.'
    return
}

$actionCount = @($events | Where-Object kind -eq 'action').Count
$criticalCount = @($events | Where-Object { $_.kind -eq 'action' -and $_.critical }).Count
$regularActionCount = $actionCount - $criticalCount
$sourceCount = @($events | Where-Object kind -eq 'source').Count
$summaryParts = @()
if ($criticalCount) { $summaryParts += "$criticalCount kritieke waarschuwing$($(if ($criticalCount -eq 1) { '' } else { 'en' }))" }
if ($regularActionCount) { $summaryParts += "$regularActionCount actie$($(if ($regularActionCount -eq 1) { '' } else { 's' }))" }
if ($sourceCount) { $summaryParts += "$sourceCount bronstoring$($(if ($sourceCount -eq 1) { '' } else { 'en' }))" }

$body = [System.Collections.Generic.List[object]]::new()
$body.Add((New-TextBlock -Text 'CTRL UPDATE' -Weight Bolder -Size Small -Color Accent))
$heading = if ($criticalCount -gt 1 -and $criticalCount -eq $events.Count) {
    "$criticalCount kritieke waarschuwingen"
}
elseif ($criticalCount) { 'Kritieke waarschuwing' }
elseif ($actionCount -gt 1 -and $actionCount -eq $events.Count) { "$actionCount acties vragen aandacht" }
elseif ($actionCount) { 'Aandacht vereist' }
else { 'Bronprobleem' }
$body.Add((New-TextBlock -Text $heading -Weight Bolder -Color Attention -Size Large -Spacing Small))
if ($events.Count -gt 1 -and -not (($criticalCount -eq $events.Count) -or ($actionCount -eq $events.Count))) {
    $body.Add((New-TextBlock -Text ($summaryParts -join ' · ') -Subtle -Spacing Small))
}

$visibleEvents = @($events | Select-Object -First $(if ($events.Count -gt 1) { 5 } else { 1 }))
for ($eventIndex = 0; $eventIndex -lt $visibleEvents.Count; $eventIndex++) {
    $event = $visibleEvents[$eventIndex]
    $eventItems = [System.Collections.Generic.List[object]]::new()
    $labelMatchesGroup = ($criticalCount -eq $events.Count -and $event.critical) -or
        ($actionCount -eq $events.Count -and -not $event.critical) -or
        ($sourceCount -eq $events.Count -and [string]$event.label -eq 'Nieuwe bronstoring')
    if (-not $labelMatchesGroup) {
        $eventItems.Add((New-TextBlock -Text ([string]$event.label).ToUpperInvariant() -Weight Bolder -Color $(if ($event.critical) { 'Attention' } else { 'Accent' }) -Size Small))
    }
    $eventItems.Add((New-TextBlock -Text ([string]$event.title) -Weight Bolder -Size Medium -Spacing Small))

    $facts = [System.Collections.Generic.List[object]]::new()
    $facts.Add([ordered]@{ title = 'Bron'; value = (Get-DisplaySource -Source ([string]$event.source)) })
    if ($event.date) { $facts.Add([ordered]@{ title = 'Actiedatum'; value = [string]$event.date }) }
    elseif ($event.published) { $facts.Add([ordered]@{ title = 'Gepubliceerd'; value = [string]$event.published }) }
    $eventItems.Add((New-FactSet -Facts $facts))

    if ($events.Count -eq 1 -and $event.summary) {
        $eventItems.Add((New-TextBlock -Text (Get-ShortText -Text ([string]$event.summary) -Length 320) -Spacing Small))
    }
    if ($events.Count -eq 1 -and @($event.why).Count -gt 0) {
        $eventItems.Add((New-TextBlock -Text 'Te beoordelen' -Weight Bolder -Color Accent -Spacing Medium))
        foreach ($point in @($event.why)) {
            $eventItems.Add((New-TextBlock -Text "• $point" -Spacing Small))
        }
    }

    $body.Add([ordered]@{
        type = 'Container'
        separator = $eventIndex -gt 0
        spacing = 'Medium'
        items = @($eventItems)
    })
}
if ($events.Count -gt $visibleEvents.Count) {
    $body.Add((New-TextBlock -Text "+ $($events.Count - $visibleEvents.Count) extra signaal/signalen op de website" -Weight Bolder -Spacing Medium))
}

$actions = @()
if ($events.Count -eq 1 -and $visibleEvents[0].link -and [string]$visibleEvents[0].link -ne $SiteUrl) {
    $actions += [ordered]@{ type = 'Action.OpenUrl'; title = 'Bekijk bron'; url = [string]$visibleEvents[0].link; style = 'positive' }
    $actions += [ordered]@{ type = 'Action.OpenUrl'; title = 'Open CTRL UPDATE'; url = $SiteUrl }
}
else {
    $actions += [ordered]@{ type = 'Action.OpenUrl'; title = 'Open CTRL UPDATE'; url = $SiteUrl; style = 'positive' }
}
$envelope = New-TeamsEnvelope -Body $body -Actions $actions

if ($PreviewOnly) {
    $envelope | ConvertTo-Json -Depth 20
    return
}

Send-TeamsEnvelope -Envelope $envelope -Url $WebhookUrl
Save-NotificationState -State $nextState -Path $StatePath
Write-Host 'Teams-melding verzonden en nulmeting bijgewerkt.' -ForegroundColor Green
