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

function New-CtrlUpdateNotificationEnvelope {
    param(
        [Parameter(Mandatory)] [object[]] $Events,
        [Parameter(Mandatory)] [string] $SiteUrl,
        [string] $HeaderLabel = 'CTRL UPDATE',
        [string] $RunUrl,
        [string] $FooterText
    )

    $criticalEvents = @($Events | Where-Object { $_.kind -eq 'action' -and $_.critical })
    $actionEvents = @($Events | Where-Object { $_.kind -eq 'action' -and -not $_.critical })
    $sourceEvents = @($Events | Where-Object kind -eq 'source')
    $body = [System.Collections.Generic.List[object]]::new()
    $body.Add((New-TextBlock -Text $HeaderLabel -Weight Bolder -Size Small -Color Accent))

    if ($Events.Count -eq 1) {
        $event = $Events[0]
        $heading = if ($event.critical) { 'Kritieke waarschuwing' }
        elseif ($event.kind -eq 'action') { 'Actie vereist' }
        else { 'Bronprobleem' }
        $headingColor = if ($event.critical) { 'Attention' } elseif ($event.kind -eq 'source') { 'Warning' } else { 'Accent' }
        $panelStyle = if ($event.critical) { 'attention' } elseif ($event.kind -eq 'source') { 'warning' } else { 'emphasis' }
        $body.Add((New-TextBlock -Text $heading -Weight Bolder -Color $headingColor -Size Large -Spacing Small))

        $items = [System.Collections.Generic.List[object]]::new()
        $items.Add((New-TextBlock -Text ([string]$event.title) -Weight Bolder -Size Medium))
        $metadata = @((Get-DisplaySource -Source ([string]$event.source)))
        if ($event.date) { $metadata += "Actiedatum $([string]$event.date)" }
        elseif ($event.published) { $metadata += [string]$event.published }
        $items.Add((New-TextBlock -Text ($metadata -join '  ·  ') -Subtle -Spacing Small))
        if ($event.summary) {
            $items.Add((New-TextBlock -Text (Get-ShortText -Text ([string]$event.summary) -Length 320) -Spacing Medium))
        }
        if (@($event.why).Count -gt 0) {
            $items.Add((New-TextBlock -Text "**Volgende stap:** $([string]@($event.why)[0])" -Color Accent -Spacing Medium))
            foreach ($point in @($event.why | Select-Object -Skip 1 -First 1)) {
                $items.Add((New-TextBlock -Text "• $point" -Spacing Small))
            }
        }
        elseif ($event.kind -eq 'source' -and $event.summary) {
            $items.Add((New-TextBlock -Text '**Volgende stap:** controleer de bronstatus bij de volgende update.' -Color Accent -Spacing Medium))
        }
        $body.Add([ordered]@{
            type = 'Container'; style = $panelStyle; spacing = 'Medium'; bleed = $false; items = @($items)
        })
    }
    else {
        $body.Add((New-TextBlock -Text 'Nieuwe aandachtspunten' -Weight Bolder -Size Large -Spacing Small))
        $summary = @()
        if ($criticalEvents.Count) { $summary += "$($criticalEvents.Count) kritiek" }
        if ($actionEvents.Count) { $summary += "$($actionEvents.Count) actie$($(if ($actionEvents.Count -eq 1) { '' } else { 's' }))" }
        if ($sourceEvents.Count) { $summary += "$($sourceEvents.Count) bronprobleem$($(if ($sourceEvents.Count -eq 1) { '' } else { 'en' }))" }
        $body.Add((New-TextBlock -Text ($summary -join '  ·  ') -Subtle -Spacing Small))

        $groups = @(
            [ordered]@{ label = 'KRITIEK'; events = $criticalEvents; color = 'Attention'; style = 'attention' }
            [ordered]@{ label = 'ACTIES'; events = $actionEvents; color = 'Accent'; style = 'emphasis' }
            [ordered]@{ label = 'BRONPROBLEMEN'; events = $sourceEvents; color = 'Warning'; style = 'warning' }
        )
        $remainingSlots = 5
        $shownCount = 0
        foreach ($group in $groups) {
            if ($group.events.Count -eq 0 -or $remainingSlots -eq 0) { continue }
            $visibleGroupEvents = @($group.events | Select-Object -First $remainingSlots)
            $groupItems = [System.Collections.Generic.List[object]]::new()
            $groupItems.Add((New-TextBlock -Text "$($group.label)  ·  $($group.events.Count)" -Weight Bolder -Color $group.color -Size Small))

            for ($index = 0; $index -lt $visibleGroupEvents.Count; $index++) {
                $event = $visibleGroupEvents[$index]
                $itemBlocks = [System.Collections.Generic.List[object]]::new()
                $itemBlocks.Add((New-TextBlock -Text ([string]$event.title) -Weight Bolder -Spacing Small))
                $metadata = @((Get-DisplaySource -Source ([string]$event.source)))
                if ($event.date) { $metadata += "Actiedatum $([string]$event.date)" }
                elseif ($event.published) { $metadata += [string]$event.published }
                $itemBlocks.Add((New-TextBlock -Text ($metadata -join '  ·  ') -Subtle -Spacing Small))

                if ($event.critical -and $event.summary) {
                    $itemBlocks.Add((New-TextBlock -Text (Get-ShortText -Text ([string]$event.summary) -Length 180) -Spacing Small))
                }
                $nextStep = @($event.why | Select-Object -First 1)
                if ($nextStep.Count) {
                    $itemBlocks.Add((New-TextBlock -Text "**Volgende stap:** $([string]$nextStep[0])" -Spacing Small))
                }
                elseif ($event.kind -eq 'source' -and $event.summary) {
                    $itemBlocks.Add((New-TextBlock -Text "**Probleem:** $(Get-ShortText -Text ([string]$event.summary) -Length 160)" -Spacing Small))
                }
                $groupItems.Add([ordered]@{
                    type = 'Container'; separator = $index -gt 0; spacing = 'Small'; items = @($itemBlocks)
                })
            }

            $body.Add([ordered]@{
                type = 'Container'; style = $group.style; spacing = 'Medium'; bleed = $false; items = @($groupItems)
            })
            $remainingSlots -= $visibleGroupEvents.Count
            $shownCount += $visibleGroupEvents.Count
        }
        if ($Events.Count -gt $shownCount) {
            $body.Add((New-TextBlock -Text "+ $($Events.Count - $shownCount) meer op CTRL UPDATE" -Weight Bolder -Color Accent -Spacing Medium))
        }
    }

    if ($FooterText) {
        $body.Add((New-TextBlock -Text $FooterText -Subtle -Spacing Medium))
    }

    $actions = @()
    if ($Events.Count -eq 1 -and $Events[0].link -and [string]$Events[0].link -ne $SiteUrl) {
        $actions += [ordered]@{ type = 'Action.OpenUrl'; title = 'Bron bekijken'; url = [string]$Events[0].link; style = 'positive' }
        $actions += [ordered]@{ type = 'Action.OpenUrl'; title = 'Naar CTRL UPDATE'; url = $SiteUrl }
    }
    else {
        $actions += [ordered]@{ type = 'Action.OpenUrl'; title = 'Naar CTRL UPDATE'; url = $SiteUrl; style = 'positive' }
    }
    if ($RunUrl) {
        $actions += [ordered]@{ type = 'Action.OpenUrl'; title = 'GitHub-run bekijken'; url = $RunUrl }
    }
    return New-TeamsEnvelope -Body $body -Actions $actions
}

if ($PSCmdlet.ParameterSetName -eq 'Test') {
    $sampleEvents = @(
        [ordered]@{
            kind = 'action'; critical = $true; label = 'Kritieke waarschuwing'
            title = 'Microsoft brengt noodupdates uit voor RDS-storingen'
            source = 'BleepingComputer'; published = '18 sep'; date = $null
            summary = 'Microsoft heeft out-of-band-updates uitgebracht voor getroffen Remote Desktop Services-omgevingen.'
            why = @('Beoordeel de noodupdate voor getroffen RDS-systemen.'); link = 'https://example.invalid/critical'
        }
        [ordered]@{
            kind = 'action'; critical = $false; label = 'Nieuwe actie'
            title = 'Nieuwe Intune-instelling vraagt voorbereiding'
            source = 'Microsoft Intune Blog'; published = '18 sep'; date = '30 sep'
            summary = 'Een beheerwijziging komt beschikbaar.'
            why = @('Controleer de huidige configuratie en plan de wijziging.'); link = 'https://example.invalid/action'
        }
        [ordered]@{
            kind = 'source'; critical = $false; label = 'Nieuwe bronstoring'
            title = 'Microsoft 365 Message Center'
            source = 'Microsoft 365 Message Center'; published = $null; date = $null
            summary = 'De bron kon tijdens deze update niet worden opgehaald.'
            why = @(); link = $SiteUrl
        }
    )
    $testEnvelope = New-CtrlUpdateNotificationEnvelope -Events $sampleEvents -SiteUrl $SiteUrl `
        -HeaderLabel 'CTRL UPDATE · ONTWERPVOORBEELD' -RunUrl $RunUrl `
        -FooterText 'Testbericht · geen beheeractie vereist'
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

$envelope = New-CtrlUpdateNotificationEnvelope -Events @($events) -SiteUrl $SiteUrl

if ($PreviewOnly) {
    $envelope | ConvertTo-Json -Depth 20
    return
}

Send-TeamsEnvelope -Envelope $envelope -Url $WebhookUrl
Save-NotificationState -State $nextState -Path $StatePath
Write-Host 'Teams-melding verzonden en nulmeting bijgewerkt.' -ForegroundColor Green
