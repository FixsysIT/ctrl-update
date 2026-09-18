<#
.SYNOPSIS
    Verzamelt Intune/Entra nieuws uit RSS/Atom feeds en (optioneel) het Microsoft 365
    Message Center, scoort elk item op relevantie, haalt er de belangrijke datums uit
    en schrijft een self-contained HTML dashboard.

.DESCRIPTION
    Feeds, categorieen, keywords en drempelwaarden staan in config/sources.json.
    Een bron toevoegen gaat het makkelijkst via .\scripts\Add-CtrlUpdateSource.ps1 <url>.

    Items die eerder zijn gezien worden onthouden in data/state.json, zodat "nieuw sinds
    vorige run" klopt ook als je het script vaker op een dag draait.

    Message Center vereist een actieve Graph-sessie met ServiceMessage.Read.All:
        Connect-MgGraph -Scopes 'ServiceMessage.Read.All'
    Zonder sessie slaat het script dat deel over met een waarschuwing.

.PARAMETER Days
    Hoeveel dagen terug items meegenomen worden. Standaard uit sources.json.

.PARAMETER SkipMessageCenter
    Sla het Message Center over, ook als het in sources.json aanstaat.

.PARAMETER Open
    Open het dashboard in de standaardbrowser na afloop.

.EXAMPLE
    .\scripts\Update-CtrlUpdate.ps1 -Days 30 -Open

.EXAMPLE
    Connect-MgGraph -Scopes 'ServiceMessage.Read.All'
    .\scripts\Update-CtrlUpdate.ps1 -Open
#>
[CmdletBinding()]
param(
    [int]    $Days,
    [switch] $SkipMessageCenter,
    [switch] $SkipAgentReview,
    [switch] $RequireAgentReview,
    [switch] $Open,

    # Haalt een enkele pagina op, laat zien welke datums eruit komen en stopt.
    # Bedoeld om de datumherkenning te testen zonder een hele run te draaien.
    [string] $TestUrl,

    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/sources.json'),
    [string] $OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist/index.html'),
    [string] $StatePath  = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data/state.json')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$outputDirectory = Split-Path -Parent $OutputPath
$stateDirectory = Split-Path -Parent $StatePath
foreach ($directory in @($outputDirectory, $stateDirectory)) {
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
}

#region Tekst-helpers ---------------------------------------------------------

function Get-NodeText {
    param($Node)

    if ($null -eq $Node)                   { return '' }
    if ($Node -is [string])                { return $Node }
    if ($Node -is [System.Xml.XmlElement]) { return $Node.InnerText }
    if ($Node -is [System.Array])          { return (($Node | ForEach-Object { Get-NodeText $_ }) -join ' ') }
    return [string]$Node
}

function ConvertFrom-HtmlText {
    param([string]$Html, [int]$MaxLength = 320)

    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }

    $text = [regex]::Replace($Html, '(?s)<(script|style).*?</\1>', ' ')
    $text = [regex]::Replace($text, '<[^>]+>', ' ')
    $text = [System.Net.WebUtility]::HtmlDecode($text)

    # Titels gebruiken vaak de typografische apostrof. Zonder deze normalisatie
    # matcht "what's new in" niet op de echte titel en glipt een maandoverzicht
    # langs het verzamelpost-filter. Codepoints staan hier expliciet, zodat dit
    # bestand zelf puur ASCII blijft.
    foreach ($code in 0x2018, 0x2019, 0x201B, 0x02BC) { $text = $text.Replace([char]$code, "'") }
    foreach ($code in 0x201C, 0x201D, 0x201E)         { $text = $text.Replace([char]$code, '"') }
    foreach ($code in 0x2013, 0x2014)                 { $text = $text.Replace([char]$code, '-') }

    $text = [regex]::Replace($text, '\s+', ' ').Trim()

    if ($text.Length -gt $MaxLength) {
        $text = $text.Substring(0, $MaxLength).TrimEnd() + '...'
    }
    return $text
}

function ConvertTo-DateTimeSafe {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor `
              [Globalization.DateTimeStyles]::AssumeUniversal
    $parsed = [datetime]::MinValue

    if ([datetime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    if ([datetime]::TryParse($Value, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-CategoryTerms {
    param($Category)

    # RSS: <category>Autopilot</category>. Atom: <category term="Autopilot"/>.
    @(@($Category) | ForEach-Object {
        if ($null -eq $_) { return }
        if ($_ -is [System.Xml.XmlElement] -and $_.term) { [string]$_.term }
        else { Get-NodeText $_ }
    } | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Get-LinkHref {
    param($Link)

    if ($null -eq $Link)    { return '' }
    if ($Link -is [string]) { return $Link }

    # Atom: <link rel="alternate" href="..."/> - soms meerdere per entry.
    $candidates = @($Link)

    $alternate = $candidates | Where-Object { $_.rel -eq 'alternate' -and $_.href } | Select-Object -First 1
    if ($alternate) { return [string]$alternate.href }

    $withHref = $candidates | Where-Object { $_.href } | Select-Object -First 1
    if ($withHref) { return [string]$withHref.href }

    return (Get-NodeText $Link)
}

#endregion

#region Config en state -------------------------------------------------------

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Config niet gevonden: $ConfigPath"
}

$config   = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$settings = $config.settings

if (-not $PSBoundParameters.ContainsKey('Days')) { $Days = $settings.defaultDays }

$today  = (Get-Date).Date
$cutoff = (Get-Date).ToUniversalTime().AddDays(-$Days)

$state = @{}
if (Test-Path -LiteralPath $StatePath) {
    try {
        $raw = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($property in $raw.PSObject.Properties) { $state[$property.Name] = $property.Value }
    }
    catch {
        Write-Warning "state.json onleesbaar, begin opnieuw: $($_.Exception.Message)"
    }
}
$isFirstRun = $state.Count -eq 0
$runStamp   = (Get-Date).ToUniversalTime().ToString('o')

function Get-TextHash {
    param([string]$Text)

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $hash  = [Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

#endregion

#region Termen matchen --------------------------------------------------------

# Een term matcht op woordgrens. Eindigt de term op *, dan is het een
# prefix-match: retir* vangt retire, retiring en retirement, maar 'ios' blijft
# los staan van 'scenarios'. Regexen worden een keer gebouwd en hergebruikt.
$termCache = @{}

function Get-TermRegex {
    param([string]$Term)

    if ($termCache.ContainsKey($Term)) { return $termCache[$Term] }

    if ($Term.EndsWith('*')) {
        $pattern = '\b' + [regex]::Escape($Term.TrimEnd('*'))
    }
    else {
        $pattern = '\b' + [regex]::Escape($Term) + '\b'
    }

    $regex = [regex]::new($pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $termCache[$Term] = $regex
    return $regex
}

function Test-Term {
    param([string]$Text, [string]$Term)

    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return (Get-TermRegex $Term).IsMatch($Text)
}

#endregion

#region Scoring ---------------------------------------------------------------

$keywordGroups = foreach ($groupName in $config.keywords.PSObject.Properties.Name) {
    $group = $config.keywords.$groupName

    # Geen maxTerms in de config = geen limiet voor die groep.
    if ($null -ne $group.maxTerms) { $maxTerms = [int]$group.maxTerms } else { $maxTerms = [int]::MaxValue }

    [PSCustomObject]@{
        Name           = $groupName
        Weight         = [int]$group.weight
        Terms          = @($group.terms)
        MaxTerms       = $maxTerms
        IsActionSignal = [bool]$group.isActionSignal
    }
}

function Get-RelevanceScore {
    param(
        [string] $Title,
        [string] $Summary,
        [int]    $Boost = 0
    )

    $multiplier   = [int]$settings.titleWeightMultiplier
    $score        = $Boost
    $hits         = [System.Collections.Generic.List[string]]::new()
    $breakdown    = [System.Collections.Generic.List[object]]::new()
    $actionSignal = $false

    if ($Boost -ne 0) {
        $breakdown.Add([PSCustomObject]@{
            label = 'Broncorrectie'
            points = $Boost
            location = 'bron'
        })
    }

    foreach ($group in $keywordGroups) {
        $applied = [System.Collections.Generic.List[object]]::new()

        foreach ($term in $group.Terms) {
            $inTitle = Test-Term -Text $Title   -Term $term
            $inBody  = Test-Term -Text $Summary -Term $term
            if (-not ($inTitle -or $inBody)) { continue }

            # Titel weegt zwaarder, maar elke term telt maar een keer mee.
            if ($inTitle) {
                $value = $group.Weight * $multiplier
                $location = 'titel'
            }
            else {
                $value = $group.Weight
                $location = 'tekst'
            }
            $applied.Add([PSCustomObject]@{
                Term = $term.TrimEnd('*')
                Value = $value
                Location = $location
                Group = $group.Name
            })
        }

        if ($applied.Count -eq 0) { continue }

        # Cap per groep: zonder dit stapelt een doc-titel vol losse topic-woorden
        # zich naar een actie-score zonder dat er iets te doen is.
        # Strafpunten (negatief gewicht) blijven ongecapt.
        if ($group.Weight -gt 0) {
            $counted = @($applied | Sort-Object Value -Descending | Select-Object -First $group.MaxTerms)
        }
        else {
            $counted = @($applied)
        }

        foreach ($hit in $counted) {
            $score += $hit.Value
            $breakdown.Add([PSCustomObject]@{
                label = [string]$hit.Term
                points = [int]$hit.Value
                location = [string]$hit.Location
            })
        }

        if ($group.Weight -gt 0) {
            foreach ($hit in $counted) { $hits.Add($hit.Term) }
            if ($group.IsActionSignal) { $actionSignal = $true }
        }
    }

    [PSCustomObject]@{
        Score        = $score
        Keywords     = @($hits | Select-Object -Unique | Select-Object -First 6)
        ActionSignal = $actionSignal
        Breakdown    = @($breakdown)
    }
}

function Get-Tier {
    param(
        [int]    $Score,
        [switch] $ActionSignal
    )

    # "Actie" betekent: er is iets te doen. Een hoge score op losse onderwerpen
    # is dat niet - daarvoor moet er een breaking change / retirement / deadline
    # in zitten. Zet requireActionSignal op false om puur op score te tieren.
    $needsSignal = [bool]$settings.requireActionSignal

    if ($Score -ge [int]$settings.actionThreshold -and ($ActionSignal -or -not $needsSignal)) {
        return 'action'
    }
    if ($Score -ge [int]$settings.watchThreshold) { return 'watch' }
    return 'info'
}

#endregion

#region Categorieen -----------------------------------------------------------

$categoryDefs = foreach ($categoryName in $config.categories.PSObject.Properties.Name) {
    [PSCustomObject]@{
        Name  = $categoryName
        Terms = @($config.categories.$categoryName)
    }
}

function Get-Categories {
    param([string]$Title, [string]$Text)

    $found = [System.Collections.Generic.List[object]]::new()

    foreach ($category in $categoryDefs) {
        $weight = 0
        foreach ($term in $category.Terms) {
            if (Test-Term -Text $Title -Term $term) { $weight += 2; continue }
            if (Test-Term -Text $Text  -Term $term) { $weight += 1 }
        }
        if ($weight -gt 0) {
            $found.Add([PSCustomObject]@{ Name = $category.Name; Weight = $weight })
        }
    }

    # Drie categorieen per item is genoeg; meer maakt de filterchips betekenisloos.
    @($found | Sort-Object Weight -Descending | Select-Object -First 3 | ForEach-Object { $_.Name })
}

#endregion

#region Datums uit de tekst halen ---------------------------------------------

$monthNames = @{
    'january' = 1; 'february' = 2; 'march'  = 3; 'april'     = 4
    'may'     = 5; 'june'     = 6; 'july'   = 7; 'august'    = 8
    'september' = 9; 'october' = 10; 'november' = 11; 'december' = 12
    'jan' = 1; 'feb' = 2; 'mar' = 3; 'apr' = 4; 'jun' = 6; 'jul' = 7
    'aug' = 8; 'sep' = 9; 'sept' = 9; 'oct' = 10; 'nov' = 11; 'dec' = 12
    'januari' = 1; 'februari' = 2; 'maart' = 3; 'mei' = 5; 'juni' = 6
    'juli' = 7; 'augustus' = 8; 'oktober' = 10
}

# Langste namen eerst, anders matcht 'jun' voordat 'juni' aan bod komt.
$monthPattern = (($monthNames.Keys | Sort-Object { $_.Length } -Descending) -join '|')

$datePatterns = @(
    # September 1, 2026  /  September 18th, 2026
    [regex]::new("\b(?<month>$monthPattern)\s+(?<day>\d{1,2})(?:st|nd|rd|th)?,?\s+(?<year>20\d{2})\b", 'IgnoreCase'),
    # 1 September 2026  /  1 september, 2026
    [regex]::new("\b(?<day>\d{1,2})(?:st|nd|rd|th)?\s+(?<month>$monthPattern),?\s+(?<year>20\d{2})\b", 'IgnoreCase'),
    # 2026-09-01
    [regex]::new("\b(?<year>20\d{2})-(?<mm>\d{2})-(?<dd>\d{2})\b"),
    # September 2026 (zonder dag) - alleen geldig met een trigger ervoor
    [regex]::new("\b(?<month>$monthPattern)\s+(?<year>20\d{2})\b", 'IgnoreCase')
)

$dateTriggerDefs = foreach ($kind in $config.dateTriggers.PSObject.Properties.Name) {
    if ($kind -eq '_comment') { continue }
    [PSCustomObject]@{
        Kind  = $kind
        Label = $config.dateTriggers.$kind.label
        Terms = @($config.dateTriggers.$kind.terms)
    }
}

function Get-KeyDates {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $results = @{}

    for ($p = 0; $p -lt $datePatterns.Count; $p++) {
        $isMonthOnly = ($p -eq 3)

        foreach ($match in $datePatterns[$p].Matches($Text)) {
            $year = [int]$match.Groups['year'].Value

            if ($match.Groups['mm'].Success) {
                $month = [int]$match.Groups['mm'].Value
                $day   = [int]$match.Groups['dd'].Value
            }
            else {
                $monthKey = $match.Groups['month'].Value.ToLowerInvariant()
                if (-not $monthNames.ContainsKey($monthKey)) { continue }
                $month = $monthNames[$monthKey]
                if ($match.Groups['day'].Success) { $day = [int]$match.Groups['day'].Value } else { $day = 1 }
            }

            if ($month -lt 1 -or $month -gt 12 -or $day -lt 1 -or $day -gt 31) { continue }
            try   { $date = [datetime]::new($year, $month, $day) }
            catch { continue }

            # Vensterbegrenzing: wat 90 dagen geleden inging is geen agenda-item
            # meer, en iets van vijf jaar verderop is bijna altijd een misparse.
            if ($date -lt $today.AddDays(-90) -or $date -gt $today.AddYears(4)) { continue }

            # Signaalwoorden staan voor de datum ("starting September 1") maar net
            # zo goed erna ("From February 1, 2027 ... will be retired"), dus beide
            # kanten meenemen. De groepen worden in configvolgorde afgelopen, dus
            # retirement wint van start als allebei voorkomen.
            $lookbackStart  = [Math]::Max(0, $match.Index - 80)
            $lookbackLength = $match.Index - $lookbackStart

            $afterStart  = $match.Index + $match.Length
            $afterLength = [Math]::Min(70, $Text.Length - $afterStart)

            $context = $Text.Substring($lookbackStart, $lookbackLength) + ' ' +
                       $Text.Substring($afterStart, $afterLength)

            $kind  = $null
            $label = $null
            foreach ($trigger in $dateTriggerDefs) {
                foreach ($term in $trigger.Terms) {
                    if (Test-Term -Text $context -Term $term) {
                        $kind  = $trigger.Kind
                        $label = $trigger.Label
                        break
                    }
                }
                if ($kind) { break }
            }

            # Een kale "September 2026" zonder signaalwoord is meestal een
            # terugverwijzing, geen afspraak. Die laten we vallen.
            if (-not $kind -and $isMonthOnly) { continue }
            if (-not $kind) { $kind = 'mentioned'; $label = 'GENOEMD' }

            $key = $date.ToString('yyyy-MM-dd')

            # Eerste (sterkste) treffer per datum wint; patronen staan op
            # volgorde van specifiek naar vaag.
            if (-not $results.ContainsKey($key)) {
                $results[$key] = [PSCustomObject]@{
                    Date        = $date
                    Kind        = $kind
                    Label       = $label
                    Approximate = [bool]($isMonthOnly -or -not $match.Groups['day'].Success)
                    Phrase      = $match.Value
                }
            }
        }
    }

    @($results.Values | Sort-Object Date)
}

# Van alle gevonden datums de belangrijkste kiezen: toekomst gaat voor verleden,
# harde afspraken gaan voor losse vermeldingen, en dan de eerstvolgende.
$kindPriority = @{ deadline = 0; retirement = 1; start = 2; available = 3; mentioned = 4 }

function Select-PrimaryDate {
    param($Dates)

    if (-not $Dates -or $Dates.Count -eq 0) { return $null }

    $future = @($Dates | Where-Object { $_.Date -ge $today -and $_.Kind -ne 'mentioned' })
    if ($future.Count -eq 0) {
        $future = @($Dates | Where-Object { $_.Date -ge $today })
    }
    if ($future.Count -eq 0) {
        # Niets in de toekomst: pak de meest recente harde datum uit het verleden.
        $past = @($Dates | Where-Object { $_.Kind -ne 'mentioned' } | Sort-Object Date -Descending)
        if ($past.Count -eq 0) { return $null }
        return $past[0]
    }

    @($future | Sort-Object @{ Expression = { $kindPriority[$_.Kind] } }, Date)[0]
}

$dutchMonths = @('jan', 'feb', 'mrt', 'apr', 'mei', 'jun', 'jul', 'aug', 'sep', 'okt', 'nov', 'dec')

function Format-DateBadge {
    param($KeyDate)

    if (-not $KeyDate) { return $null }

    $date     = $KeyDate.Date
    $daysAway = [int]($date - $today).TotalDays

    if ($KeyDate.Approximate) { $text = "$($dutchMonths[$date.Month - 1]) $($date.Year)" }
    else                      { $text = "$($date.Day) $($dutchMonths[$date.Month - 1]) $($date.Year)" }

    # Een wijziging die een week geleden inging is urgenter dan een deadline over
    # vier maanden: die loopt nu en je hebt hem gemist. Daarom een eigen niveau.
    $lookback = [int]$settings.agendaLookbackDays

    if ($daysAway -lt -$lookback)                          { $urgency = 'past' }
    elseif ($daysAway -lt 0)                               { $urgency = 'running' }
    elseif ($daysAway -le [int]$settings.urgentWithinDays) { $urgency = 'urgent' }
    elseif ($daysAway -le [int]$settings.soonWithinDays)   { $urgency = 'soon' }
    else                                                   { $urgency = 'planned' }

    if ($daysAway -lt 0)      { $relative = "loopt al $([Math]::Abs($daysAway)) dagen" }
    elseif ($daysAway -eq 0)  { $relative = 'vandaag' }
    elseif ($daysAway -eq 1)  { $relative = 'morgen' }
    else                      { $relative = "over $daysAway dagen" }

    if ($urgency -eq 'past') { $relative = "$([Math]::Abs($daysAway)) dagen geleden" }

    [PSCustomObject]@{
        iso      = $date.ToString('yyyy-MM-dd')
        label    = $KeyDate.Label
        text     = $text
        day      = $date.Day
        month    = $dutchMonths[$date.Month - 1]
        year     = $date.Year
        approx   = [bool]$KeyDate.Approximate
        daysAway = $daysAway
        relative = $relative
        urgency  = $urgency
        kind     = $KeyDate.Kind
    }
}

#endregion

#region Verzamelposts en uitleg bij acties ------------------------------------

# Geeft terug waarom een item gedempt wordt, of $null als dat niet zo is.
# 'digest' = maandoverzicht of nieuwsbrief, 'guide' = handleiding of uitleg.
# Allebei noemen ze actiewoorden zonder dat er iets te doen is.
function Get-DemoteKind {
    param([string]$Title)

    foreach ($term in @($config.digest.terms)) {
        if (Test-Term -Text $Title -Term $term) { return 'digest' }
    }
    foreach ($term in @($config.digest.guideTerms)) {
        if (Test-Term -Text $Title -Term $term) { return 'guide' }
    }
    return $null
}

# Haalt de zinnen op waar het om draait: die met een actiewoord of met de datum
# die we als hoofddatum hebben gekozen. Dat is de uitleg bij een rood item -
# letterlijk uit de bron, zodat er niets bij verzonnen wordt.
function Get-ActionContext {
    param(
        [string] $Text,
        $KeyDate,
        [string] $DatePhrase
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $actionGroup = $keywordGroups | Where-Object { $_.IsActionSignal } | Select-Object -First 1
    if (-not $actionGroup) { return @() }

    $maxLength = [int]$settings.actionSentenceLength
    $sentences = [regex]::Split($Text, '(?<=[.!?])\s+(?=[A-Z0-9"])')

    $scored = foreach ($sentence in $sentences) {
        $clean = $sentence.Trim()
        if ($clean.Length -lt 40 -or $clean.Length -gt $maxLength * 2) { continue }

        $weight = 0
        $terms  = [System.Collections.Generic.List[string]]::new()

        foreach ($term in $actionGroup.Terms) {
            if (Test-Term -Text $clean -Term $term) {
                $weight += 2
                $terms.Add($term.TrimEnd('*'))
            }
        }

        # Een zin met de datum erin legt uit wanneer het gebeurt.
        if ($DatePhrase -and $clean.Contains($DatePhrase)) { $weight += 3 }

        # Zinnen die de lezer aanspreken bevatten meestal de instructie.
        foreach ($cue in 'you should', 'you must', 'you need to', 'make sure',
                         'we recommend', 'recommended', 'to avoid', 'before this date',
                         'take action', 'admins should', 'customers should', 'configure',
                         'ensure that', 'migrate') {
            if (Test-Term -Text $clean -Term $cue) { $weight += 2 }
        }

        if ($weight -eq 0) { continue }

        if ($clean.Length -gt $maxLength) {
            $clean = $clean.Substring(0, $maxLength).TrimEnd() + '...'
        }

        [PSCustomObject]@{ Text = $clean; Weight = $weight; Terms = @($terms | Select-Object -Unique) }
    }

    @($scored |
        Sort-Object Weight -Descending |
        Select-Object -First ([int]$settings.actionMaxSentences) |
        ForEach-Object { [PSCustomObject]@{ text = $_.Text; terms = @($_.Terms) } })
}

#endregion

#region Datumherkenning testen ------------------------------------------------

if ($TestUrl) {
    $page = Invoke-WebRequest -Uri $TestUrl `
                              -Headers @{
                                  'User-Agent'      = $settings.userAgent
                                  'Accept'          = 'text/html,application/xhtml+xml,*/*;q=0.8'
                                  'Accept-Language' = 'en-US,en;q=0.9'
                              } `
                              -TimeoutSec 25 -MaximumRedirection 5 -UseBasicParsing

    $raw = [regex]::Replace($page.Content, '(?is)<(nav|header|footer|aside|form)\b.*?</\1>', ' ')
    $articleMatch = [regex]::Match($raw, '(?is)<(article|main)\b[^>]*>(.*?)</\1>')
    if ($articleMatch.Success) { $raw = $articleMatch.Groups[2].Value }

    $text  = ConvertFrom-HtmlText $raw ([int]$settings.scoreTextLength)
    $dates = Get-KeyDates $text

    Write-Host ''
    Write-Host "Testpagina: $TestUrl" -ForegroundColor Cyan
    Write-Host "  tekst: $($text.Length) tekens   gevonden datums: $($dates.Count)"
    Write-Host ''

    if ($dates) {
        $dates | ForEach-Object {
            $badge = Format-DateBadge $_
            [PSCustomObject]@{
                Label   = $badge.label
                Datum   = $badge.text
                Over    = $badge.relative
                Urgentie= $badge.urgency
                Soort   = $_.Kind
                Gevonden= $_.Phrase
            }
        } | Format-Table -AutoSize | Out-String -Width 160 | Write-Host

        $primary = Select-PrimaryDate $dates
        $badge   = Format-DateBadge $primary
        Write-Host "Gekozen als hoofddatum: $($badge.label) $($badge.text) ($($badge.relative))" -ForegroundColor Green
    }
    else {
        Write-Host 'Geen datums herkend.' -ForegroundColor Yellow
    }

    $relevance = Get-RelevanceScore -Title '' -Summary $text
    Write-Host ''
    Write-Host "Score zonder titel: $($relevance.Score)   actie-signaal: $($relevance.ActionSignal)"
    Write-Host "Trefwoorden: $($relevance.Keywords -join ', ')"
    Write-Host "Categorieen: $((Get-Categories -Title '' -Text $text) -join ', ')"
    return
}

#endregion

#region Feeds ophalen ---------------------------------------------------------

$items      = [System.Collections.Generic.List[object]]::new()
$feedStatus = [System.Collections.Generic.List[object]]::new()

$enabledFeeds = @($config.feeds | Where-Object { $_.enabled -ne $false })
$feedIndex    = 0

foreach ($feed in $enabledFeeds) {
    $feedIndex++
    Write-Progress -Activity 'Feeds ophalen' -Status $feed.name `
                   -PercentComplete (($feedIndex / $enabledFeeds.Count) * 100)

    $count = 0
    try {
        # Sommige bronnen (microsoft.com/security/blog, ourcloudnetwork) geven 403
        # op een kale script-UA. Met browser-headers komen ze wel door.
        $headers = @{
            'User-Agent'      = $settings.userAgent
            'Accept'          = 'application/rss+xml,application/xml,text/xml,*/*;q=0.8'
            'Accept-Language' = 'en-US,en;q=0.9'
        }

        $response = Invoke-WebRequest -Uri $feed.url `
                                      -Headers $headers `
                                      -TimeoutSec $settings.timeoutSec `
                                      -MaximumRedirection 5 `
                                      -UseBasicParsing

        $content = $response.Content.TrimStart([char]0xFEFF, ' ', "`t", "`r", "`n")
        $xml     = [xml]$content

        # RSS 2.0 en Atom hebben andere node-namen; dot-notatie negeert namespaces.
        if     ($xml.rss)  { $entries = @($xml.rss.channel.item) }
        elseif ($xml.feed) { $entries = @($xml.feed.entry) }
        else               { $entries = @() }

        foreach ($entry in $entries) {
            if ($null -eq $entry) { continue }

            $title = ConvertFrom-HtmlText (Get-NodeText $entry.title) 200
            if ([string]::IsNullOrWhiteSpace($title)) { continue }

            $link = Get-LinkHref $entry.link
            if ([string]::IsNullOrWhiteSpace($link)) { $link = Get-NodeText $entry.id }

            $published = ConvertTo-DateTimeSafe (Get-NodeText $entry.pubDate)
            if (-not $published) { $published = ConvertTo-DateTimeSafe (Get-NodeText $entry.published) }
            if (-not $published) { $published = ConvertTo-DateTimeSafe (Get-NodeText $entry.updated) }
            if (-not $published) { continue }
            if ($published -lt $cutoff) { continue }

            # content:encoded heeft de hele post, description vaak maar een
            # fragment - dus die eerst. PowerShell adresseert een genamespacet
            # element op de lokale naam, vandaar 'encoded'.
            $body = Get-NodeText $entry.encoded
            if ([string]::IsNullOrWhiteSpace($body)) { $body = Get-NodeText $entry.description }
            if ([string]::IsNullOrWhiteSpace($body)) { $body = Get-NodeText $entry.summary }
            if ([string]::IsNullOrWhiteSpace($body)) { $body = Get-NodeText $entry.content }

            # Scoren op de volledige tekst, tonen op een ingekorte versie: een
            # "will be retired" halverwege de post moet wel meetellen.
            $fullText = ConvertFrom-HtmlText $body ([int]$settings.scoreTextLength)
            $summary  = ConvertFrom-HtmlText $body ([int]$settings.summaryLength)

            # De bron levert vaak zijn eigen rubrieken mee (Autopilot, Windows 11).
            # Die zijn betrouwbaarder dan wat wij uit de tekst afleiden.
            $nativeCategories = @(Get-CategoryTerms $entry.category)

            $relevance  = Get-RelevanceScore -Title $title -Summary $fullText -Boost ([int]$feed.boost)

            # De eigen publicatiedatum staat vaak in de tekst ("Posted on 31 August
            # 2026"). Dat is geen afspraak, dus die filteren we weg.
            $keyDates   = @(Get-KeyDates "$title. $fullText" |
                            Where-Object { [Math]::Abs(($_.Date - $published.Date).TotalDays) -gt 1 })
            $primary    = Select-PrimaryDate $keyDates

            # Een harde datum in de toekomst is zelf een actie-signaal: daar moet
            # iets voor gebeuren, ook als het woord "retirement" ontbreekt.
            $dateSignal = $primary -and $primary.Date -ge $today -and $primary.Kind -in @('deadline', 'retirement', 'start')

            $score = $relevance.Score
            $scoreBreakdown = @($relevance.Breakdown)
            if ($dateSignal) {
                $score += 3
                $scoreBreakdown += [PSCustomObject]@{ label = 'Concrete wijzigingsdatum'; points = 3; location = 'datum' }
            }

            # Een maandoverzicht of nieuwsbrief vat andermans wijzigingen samen.
            # Die mag in de lijst, maar niet rood worden en niet in de agenda:
            # de post die er echt over gaat staat er los ook in.
            $demote = Get-DemoteKind $title
            # Zoekfeeds uit Learn Docs bevatten vooral naslag en handleidingen.
            # Zonder concrete wijzigingsdatum is zo'n pagina een nuttig signaal,
            # maar geen rode actie voor de beheerder.
            if (-not $demote -and $feed.name -like 'Learn Docs*' -and -not $primary) {
                $demote = 'reference'
            }
            $tier   = Get-Tier -Score $score -ActionSignal:($relevance.ActionSignal -or $dateSignal)
            if ($demote -and $tier -eq 'action') { $tier = 'watch' }

            if ($link) { $id = $link } else { $id = "$($feed.name)|$title" }

            $items.Add([PSCustomObject]@{
                Id         = $id
                Title      = $title
                Link       = $link
                Source     = $feed.name
                Tag        = $feed.tag
                Published  = $published
                Summary    = $summary
                Score      = $score
                ScoreBreakdown = @($scoreBreakdown)
                Tier       = $tier
                Demote     = $demote
                ActionCtx  = @(Get-ActionContext -Text $fullText -KeyDate $primary -DatePhrase $(if ($primary) { $primary.Phrase } else { $null }))
                Keywords   = @($relevance.Keywords)
                Categories = @(Get-Categories -Title "$title $($nativeCategories -join ' ')" -Text $fullText)
                NativeTags = @($nativeCategories | Select-Object -First 5)
                KeyDate    = Format-DateBadge $primary
                AllDates   = @($keyDates | Where-Object { $_.Date -ge $today } | Select-Object -First 4 | ForEach-Object { Format-DateBadge $_ })
                Kind       = 'feed'
                Channel    = $(if ($feed.tag -eq 'Microsoft') { 'official' } else { 'community' })
                FullText   = $fullText
                Enriched   = $false
                Boost      = [int]$feed.boost
                Deadline   = $null
                IsNew      = -not $state.ContainsKey($id)
            })
            $count++
        }

        $feedStatus.Add([PSCustomObject]@{ Source = $feed.name; Status = 'OK'; Items = $count; Detail = '' })
    }
    catch {
        $failure = $_.Exception.Message
        Write-Warning "$($feed.name): $failure"
        $feedStatus.Add([PSCustomObject]@{ Source = $feed.name; Status = 'FOUT'; Items = 0; Detail = $failure })
    }
}
Write-Progress -Activity 'Feeds ophalen' -Completed

#endregion

#region Samengestelde praktijktips -------------------------------------------

# Sommige uitzonderlijk bruikbare handleidingen verdienen een vaste plek in de
# radar, ook als ze buiten het gewone nieuwsvenster vallen. Ze blijven gewone
# bronlinks: de agent vat ze samen, maar de oorspronkelijke auteur blijft leidend.
foreach ($curated in @($config.curatedArticles)) {
    try {
        $page = Invoke-WebRequest -Uri $curated.url `
                                  -Headers @{
                                      'User-Agent' = $settings.userAgent
                                      'Accept' = 'text/html,application/xhtml+xml,*/*;q=0.8'
                                      'Accept-Language' = 'en-US,en;q=0.9'
                                  } `
                                  -TimeoutSec ([int]$settings.timeoutSec) `
                                  -MaximumRedirection 5 -UseBasicParsing

        $raw = [regex]::Replace($page.Content, '(?is)<(nav|header|footer|aside|form)\b.*?</\1>', ' ')
        $articleMatch = [regex]::Match($raw, '(?is)<article\b[^>]*>(.*?)</article>')
        if ($articleMatch.Success) { $raw = $articleMatch.Groups[1].Value }

        $fullText = ConvertFrom-HtmlText $raw ([int]$settings.scoreTextLength)
        $summary = ConvertFrom-HtmlText $raw ([int]$settings.summaryLength)
        $published = ConvertTo-DateTimeSafe ([string]$curated.published)
        if (-not $published) { $published = (Get-Date).ToUniversalTime() }
        $title = [string]$curated.title
        $relevance = Get-RelevanceScore -Title $title -Summary $fullText
        $keyDates = @(Get-KeyDates "$title. $fullText" |
                      Where-Object { [Math]::Abs(($_.Date - $published.Date).TotalDays) -gt 1 })
        $primary = Select-PrimaryDate $keyDates
        $dateSignal = $primary -and $primary.Date -ge $today -and $primary.Kind -in @('deadline', 'retirement', 'start')
        $score = $relevance.Score
        $scoreBreakdown = @($relevance.Breakdown)
        if ($dateSignal) {
            $score += 3
            $scoreBreakdown += [PSCustomObject]@{ label = 'Concrete wijzigingsdatum'; points = 3; location = 'datum' }
        }
        $demote = Get-DemoteKind $title
        if (-not $demote) { $demote = 'guide' }
        $tier = Get-Tier -Score $score -ActionSignal:($relevance.ActionSignal -or $dateSignal)
        if ($tier -eq 'action') { $tier = 'watch' }
        $id = [string]$curated.url

        $items.Add([PSCustomObject]@{
            Id = $id; Title = $title; Link = [string]$curated.url
            Source = [string]$curated.source; Tag = [string]$curated.tag
            Published = $published; Summary = $summary; Score = $score
            ScoreBreakdown = @($scoreBreakdown); Tier = $tier; Demote = $demote
            ActionCtx = @(Get-ActionContext -Text $fullText -KeyDate $primary -DatePhrase $(if ($primary) { $primary.Phrase } else { $null }))
            Keywords = @($relevance.Keywords)
            Categories = @(Get-Categories -Title "$title $(@($curated.nativeTags) -join ' ')" -Text $fullText)
            NativeTags = @($curated.nativeTags); KeyDate = Format-DateBadge $primary
            AllDates = @($keyDates | Where-Object { $_.Date -ge $today } | Select-Object -First 4 | ForEach-Object { Format-DateBadge $_ })
            Kind = 'feed'; Channel = 'community'; FullText = $fullText; Enriched = $true
            Boost = 0; Deadline = $null; IsNew = -not $state.ContainsKey($id); Curated = $true
        })
    }
    catch {
        Write-Warning "Samengestelde tip '$($curated.title)' niet opgehaald: $($_.Exception.Message)"
    }
}

#endregion

#region Artikelen verrijken ---------------------------------------------------

# Veel feeds leveren maar een fragment van 150 tekens. Daar staat nooit een
# "starting September 1, 2026" in, en dat is precies wat je wilt zien. Voor de
# kandidaten die er al uitspringen halen we daarom de artikelpagina zelf op.
# Gelimiteerd op maxPages, want dit is de enige trage stap in het script.
$enrich = $config.enrich

if ($enrich.enabled -and $items.Count -gt 0) {

    $candidates = @($items |
        Where-Object {
            $_.Link -match '^https?://' -and
            ($_.Score -ge [int]$enrich.minScore -or $_.Tag -eq 'Microsoft' -or $_.FullText.Length -lt [int]$enrich.shortTextBelow)
        } |
        Sort-Object Score -Descending |
        Select-Object -First ([int]$enrich.maxPages))

    $enrichIndex = 0
    $enrichedOk  = 0
    $enrichShort = 0   # pagina leverde niet meer tekst dan de feed al gaf
    $enrichFail  = 0   # ophalen of parsen mislukt

    foreach ($item in $candidates) {
        $enrichIndex++
        Write-Progress -Activity 'Artikelen verrijken' -Status $item.Title `
                       -PercentComplete (($enrichIndex / $candidates.Count) * 100)

        try {
            $page = Invoke-WebRequest -Uri $item.Link `
                                      -Headers @{
                                          'User-Agent'      = $settings.userAgent
                                          'Accept'          = 'text/html,application/xhtml+xml,*/*;q=0.8'
                                          'Accept-Language' = 'en-US,en;q=0.9'
                                      } `
                                      -TimeoutSec ([int]$enrich.timeoutSec) `
                                      -MaximumRedirection 5 `
                                      -UseBasicParsing

            # Navigatie en footers weg, anders vissen we datums uit het menu.
            $raw = $page.Content
            $raw = [regex]::Replace($raw, '(?is)<(nav|header|footer|aside|form)\b.*?</\1>', ' ')

            $articleMatch = [regex]::Match($raw, '(?is)<(article|main)\b[^>]*>(.*?)</\1>')
            if ($articleMatch.Success) { $raw = $articleMatch.Groups[2].Value }

            $pageText = ConvertFrom-HtmlText $raw ([int]$settings.scoreTextLength)
            if ($pageText.Length -le $item.FullText.Length) { $enrichShort++; continue }

            $relevance = Get-RelevanceScore -Title $item.Title -Summary $pageText -Boost $item.Boost
            $keyDates  = @(Get-KeyDates "$($item.Title). $pageText" |
                           Where-Object { [Math]::Abs(($_.Date - $item.Published.Date).TotalDays) -gt 1 })
            $primary   = Select-PrimaryDate $keyDates

            $dateSignal = $primary -and $primary.Date -ge $today -and
                          $primary.Kind -in @('deadline', 'retirement', 'start')

            $score = $relevance.Score
            $scoreBreakdown = @($relevance.Breakdown)
            if ($dateSignal) {
                $score += 3
                $scoreBreakdown += [PSCustomObject]@{ label = 'Concrete wijzigingsdatum'; points = 3; location = 'datum' }
            }

            # De rijkere tekst mag een item alleen omhoog trekken, niet omlaag:
            # een fragment dat al hoog scoorde had die woorden echt.
            if ($score -gt $item.Score) {
                $item.Score    = $score
                $item.Keywords = @($relevance.Keywords)
                $item.ScoreBreakdown = @($scoreBreakdown)
            }

            # Na verrijking opnieuw bepalen: een Learn Docs-pagina met een echte
            # wijzigingsdatum mag wel uit de naslag-demotie komen.
            $item.Demote = Get-DemoteKind $item.Title
            if (-not $item.Demote -and $item.Source -like 'Learn Docs*' -and -not $primary) {
                $item.Demote = 'reference'
            }

            $newTier = Get-Tier -Score $item.Score -ActionSignal:($relevance.ActionSignal -or $dateSignal)
            if ($item.Demote -and $newTier -eq 'action') { $newTier = 'watch' }

            $item.Tier       = $newTier
            $item.ActionCtx  = @(Get-ActionContext -Text $pageText -KeyDate $primary -DatePhrase $(if ($primary) { $primary.Phrase } else { $null }))
            $item.Categories = @(Get-Categories -Title "$($item.Title) $($item.NativeTags -join ' ')" -Text $pageText)
            $item.KeyDate    = Format-DateBadge $primary
            $item.AllDates   = @($keyDates | Where-Object { $_.Date -ge $today } |
                                 Select-Object -First 4 | ForEach-Object { Format-DateBadge $_ })
            $item.FullText   = $pageText
            $item.Enriched   = $true

            # Feeds met een fragment van 150 tekens krijgen nu een echte samenvatting.
            if ($item.Summary.Length -lt 140) {
                $item.Summary = ConvertFrom-HtmlText $pageText ([int]$settings.summaryLength)
            }

            $enrichedOk++
        }
        catch {
            $enrichFail++
            Write-Verbose "Verrijken mislukt voor $($item.Link): $($_.Exception.Message)"
        }
    }
    Write-Progress -Activity 'Artikelen verrijken' -Completed

    $feedStatus.Add([PSCustomObject]@{
        Source = 'Artikelen verrijkt'
        Status = 'OK'
        Items  = $enrichedOk
        Detail = "$enrichedOk verrijkt van $($candidates.Count) kandidaten " +
                 "($enrichShort leverden niet meer tekst, $enrichFail niet op te halen)"
    })
}

#endregion

#region Message Center --------------------------------------------------------

$useMessageCenter = $config.messageCenter.enabled -and -not $SkipMessageCenter

if ($useMessageCenter) {
    if (-not (Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue)) {
        Write-Warning 'Microsoft.Graph module niet gevonden - Message Center overgeslagen.'
        $feedStatus.Add([PSCustomObject]@{
            Source = 'Message Center'; Status = 'OVERGESLAGEN'; Items = 0
            Detail = 'Microsoft.Graph module ontbreekt'
        })
    }
    else {
        try {
            $mcScoring = $config.messageCenter.scoring
            $wanted    = @($config.messageCenter.services)
            $uri       = 'https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/messages'
            $mcCount   = 0

            do {
                $page = Invoke-MgGraphRequest -Method GET -Uri $uri

                foreach ($message in $page.value) {
                    $published = ConvertTo-DateTimeSafe $message.lastModifiedDateTime
                    if (-not $published -or $published -lt $cutoff) { continue }

                    # services is een collection; $filter werkt er niet op, dus client-side.
                    $matchesService = $false
                    foreach ($service in @($message.services)) {
                        foreach ($want in $wanted) {
                            if ($service -like "*$want*") { $matchesService = $true }
                        }
                    }
                    if (-not $matchesService) { continue }

                    $fullText = ConvertFrom-HtmlText $message.body.content ([int]$settings.scoreTextLength)
                    $summary  = ConvertFrom-HtmlText $message.body.content ([int]$settings.summaryLength)

                    $relevance = Get-RelevanceScore -Title $message.title -Summary $fullText
                    $score     = $relevance.Score
                    $scoreBreakdown = @($relevance.Breakdown)
                    $signals   = [System.Collections.Generic.List[string]]::new()

                    # Message Center scoort vooral op eigen metadata, niet op keywords.
                    switch ($message.category) {
                        'planForChange'     {
                            $score += $mcScoring.planForChange; $signals.Add('plan for change')
                            $scoreBreakdown += [PSCustomObject]@{ label = 'Message Center: wijziging plannen'; points = [int]$mcScoring.planForChange; location = 'metadata' }
                        }
                        'preventOrFixIssue' {
                            $score += $mcScoring.preventOrFixIssue; $signals.Add('prevent or fix')
                            $scoreBreakdown += [PSCustomObject]@{ label = 'Message Center: probleem voorkomen of oplossen'; points = [int]$mcScoring.preventOrFixIssue; location = 'metadata' }
                        }
                    }
                    if ($message.isMajorChange) {
                        $score += $mcScoring.isMajorChange
                        $signals.Add('major change')
                        $scoreBreakdown += [PSCustomObject]@{ label = 'Message Center: grote wijziging'; points = [int]$mcScoring.isMajorChange; location = 'metadata' }
                    }

                    $deadline = ConvertTo-DateTimeSafe $message.actionRequiredByDateTime
                    if ($deadline) {
                        $score += $mcScoring.actionRequiredByDateTime
                        $signals.Add('action required')
                        $scoreBreakdown += [PSCustomObject]@{ label = 'Message Center: actiedeadline'; points = [int]$mcScoring.actionRequiredByDateTime; location = 'metadata' }
                    }

                    switch ($message.severity) {
                        'high'     {
                            $score += $mcScoring.severityHigh; $signals.Add('severity high')
                            $scoreBreakdown += [PSCustomObject]@{ label = 'Message Center: hoge ernst'; points = [int]$mcScoring.severityHigh; location = 'metadata' }
                        }
                        'critical' {
                            $score += $mcScoring.severityCritical; $signals.Add('severity critical')
                            $scoreBreakdown += [PSCustomObject]@{ label = 'Message Center: kritieke ernst'; points = [int]$mcScoring.severityCritical; location = 'metadata' }
                        }
                    }

                    # De harde deadline uit de Graph-metadata wint van elke datum
                    # die we uit de lopende tekst zouden vissen.
                    $keyDates = Get-KeyDates "$($message.title). $fullText"
                    if ($deadline) {
                        $primary = [PSCustomObject]@{
                            Date = $deadline.Date; Kind = 'deadline'; Label = 'DEADLINE'
                            Approximate = $false; Phrase = 'actionRequiredByDateTime'
                        }
                    }
                    else {
                        $primary = Select-PrimaryDate $keyDates
                    }

                    $id = "MC:$($message.id)"

                    $items.Add([PSCustomObject]@{
                        Id         = $id
                        Title      = "$($message.id) - $($message.title)"
                        Link       = 'https://admin.microsoft.com/#/MessageCenter/:/messages/' + $message.id
                        Source     = 'Message Center'
                        Tag        = 'Tenant'
                        Published  = $published
                        Summary    = $summary
                        Score      = $score
                        ScoreBreakdown = @($scoreBreakdown)
                        # Message Center-metadata (plan for change, deadline, major change)
                        # is zelf al het actie-signaal - keywords zijn daar bijvangst.
                        Tier       = Get-Tier -Score $score -ActionSignal:($signals.Count -gt 0 -or $relevance.ActionSignal)
                        Demote     = $null
                        ActionCtx  = @(Get-ActionContext -Text $fullText -KeyDate $primary -DatePhrase $(if ($primary) { $primary.Phrase } else { $null }))
                        Keywords   = @(@($signals) + @($relevance.Keywords) | Select-Object -Unique | Select-Object -First 6)
                        Categories = @(Get-Categories -Title $message.title -Text $fullText)
                        NativeTags = @($message.services)
                        KeyDate    = Format-DateBadge $primary
                        AllDates   = @($keyDates | Where-Object { $_.Date -ge $today } | Select-Object -First 4 | ForEach-Object { Format-DateBadge $_ })
                        Kind       = 'messagecenter'
                        Channel    = 'tenant'
                        FullText   = $fullText
                        Enriched   = $true
                        Boost      = 0
                        Deadline   = $null
                        IsNew      = -not $state.ContainsKey($id)
                    })
                    $mcCount++
                }

                $uri = $page.'@odata.nextLink'
            } while ($uri)

            $feedStatus.Add([PSCustomObject]@{ Source = 'Message Center'; Status = 'OK'; Items = $mcCount; Detail = '' })
        }
        catch {
            $failure = $_.Exception.Message
            Write-Warning "Message Center: $failure"

            if ($failure -match 'Authentication|token|Connect-MgGraph|Unauthorized') {
                $hint = "Draai eerst: Connect-MgGraph -Scopes 'ServiceMessage.Read.All'"
            }
            else { $hint = $failure }

            $feedStatus.Add([PSCustomObject]@{ Source = 'Message Center'; Status = 'FOUT'; Items = 0; Detail = $hint })
        }
    }
}
elseif ($config.messageCenter.enabled -and $SkipMessageCenter) {
    $feedStatus.Add([PSCustomObject]@{
        Source = 'Message Center'; Status = 'OVERGESLAGEN'; Items = 0
        Detail = "Run uitgevoerd met -SkipMessageCenter; verbind Graph met ServiceMessage.Read.All voor tenantberichten"
    })
}

#endregion

#region Ontdubbelen, sorteren en state opslaan --------------------------------

# Categoriefeeds overlappen met de hoofdfeed van dezelfde site, dus dezelfde post
# komt meerdere keren binnen. Hoogste score wint, de andere bronnen worden als
# herkomst bij het item bewaard.
$deduped = foreach ($group in ($items | Group-Object Id)) {
    $best = @($group.Group | Sort-Object Score -Descending)[0]
    $also = @($group.Group | Where-Object { $_.Source -ne $best.Source } |
              Select-Object -ExpandProperty Source -Unique)

    $best | Add-Member -NotePropertyName AlsoIn -NotePropertyValue $also -Force
    $best
}

$duplicatesRemoved = $items.Count - @($deduped).Count

# De regelscore is snel en uitlegbaar; de agentreview doet daarna de inhoudelijke
# eindredactie. De inhoudshash maakt de reviewcache veilig: alleen gewijzigde
# artikelen gaan opnieuw naar Codex.
$reviewedCount = 0
$reviewStatus  = 'uitgeschakeld'
$reviewSettings = $config.agentReview

foreach ($item in $deduped) {
    $item | Add-Member -NotePropertyName OriginalTitle -NotePropertyValue $item.Title -Force
    $item | Add-Member -NotePropertyName EnglishTitle -NotePropertyValue $item.Title -Force
    $item | Add-Member -NotePropertyName EnglishSummary -NotePropertyValue $item.Summary -Force
    $item | Add-Member -NotePropertyName EnglishActionCtx -NotePropertyValue @($item.ActionCtx) -Force
    $item | Add-Member -NotePropertyName AgentReviewed -NotePropertyValue $false -Force
    $item | Add-Member -NotePropertyName AgentConfidence -NotePropertyValue $null -Force
    $item | Add-Member -NotePropertyName AgentReason -NotePropertyValue '' -Force
    $item | Add-Member -NotePropertyName AgentReasonEn -NotePropertyValue '' -Force
    $item | Add-Member -NotePropertyName ReviewKind -NotePropertyValue '' -Force
    $hashInput = "$($item.Title)`n$($item.Source)`n$($item.FullText)"
    $item | Add-Member -NotePropertyName ContentHash -NotePropertyValue (Get-TextHash $hashInput) -Force
}

if ($reviewSettings.enabled -and -not $SkipAgentReview -and @($deduped).Count -gt 0) {
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $reviewInputPath = Join-Path $projectRoot 'data/review-input.json'
    $reviewOutputPath = if ([IO.Path]::IsPathRooted([string]$reviewSettings.outputPath)) {
        [string]$reviewSettings.outputPath
    } else {
        Join-Path $projectRoot ([string]$reviewSettings.outputPath)
    }

    $reviewInput = [PSCustomObject]@{
        generated = (Get-Date).ToUniversalTime().ToString('o')
        items = @($deduped | ForEach-Object {
            [PSCustomObject]@{
                id = $_.Id
                contentHash = $_.ContentHash
                title = $_.Title
                source = $_.Source
                channel = $_.Channel
                published = $_.Published.ToString('yyyy-MM-dd')
                text = $_.FullText
                rulesScore = $_.Score
                proposedTier = $_.Tier
                demote = $_.Demote
                detectedCategories = @($_.Categories)
                detectedDates = @($_.AllDates)
            }
        })
    }
    $reviewInput | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reviewInputPath -Encoding UTF8

    try {
        & (Join-Path $PSScriptRoot 'Invoke-CtrlUpdateReview.ps1') `
            -InputPath $reviewInputPath -OutputPath $reviewOutputPath -ConfigPath $ConfigPath

        $reviewData = Get-Content -LiteralPath $reviewOutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $reviewById = @{}
        foreach ($review in @($reviewData.items)) { $reviewById[[string]$review.id] = $review }

        foreach ($item in $deduped) {
            if (-not $reviewById.ContainsKey([string]$item.Id)) { continue }
            $review = $reviewById[[string]$item.Id]
            if ([string]$review.contentHash -ne $item.ContentHash) { continue }

            if (-not [string]::IsNullOrWhiteSpace([string]$review.titleNl)) { $item.Title = [string]$review.titleNl }
            if (-not [string]::IsNullOrWhiteSpace([string]$review.summaryNl)) { $item.Summary = [string]$review.summaryNl }
            if (-not [string]::IsNullOrWhiteSpace([string]$review.titleEn)) { $item.EnglishTitle = [string]$review.titleEn }
            if (-not [string]::IsNullOrWhiteSpace([string]$review.summaryEn)) { $item.EnglishSummary = [string]$review.summaryEn }
            $item.ActionCtx = @($review.whyNl | Where-Object { $_ } | Select-Object -First 3 | ForEach-Object {
                [PSCustomObject]@{ text = [string]$_ }
            })
            $item.EnglishActionCtx = @($review.whyEn | Where-Object { $_ } | Select-Object -First 3 | ForEach-Object {
                [PSCustomObject]@{ text = [string]$_ }
            })
            # Ook bij lage zekerheid is de Nederlandse redactie bruikbaar. Alleen
            # classificatie en urgentie vereisen de ingestelde minimumzekerheid.
            if ([double]$review.confidence -ge [double]$reviewSettings.minimumConfidence) {
                $item.Categories = @($review.categories | Where-Object { $_ -in $config.categories.PSObject.Properties.Name } | Select-Object -Unique -First 3)

                $agentTier = [string]$review.tier
                if ($agentTier -in @('action', 'watch', 'info')) {
                    if ($item.Demote -and $agentTier -eq 'action') { $agentTier = 'watch' }
                    $item.Tier = $agentTier
                }
            }

            $item.AgentReviewed = $true
            $item.AgentConfidence = [Math]::Round([double]$review.confidence, 2)
            $item.AgentReason = [string]$review.reasonNl
            $item.AgentReasonEn = [string]$review.reasonEn
            $item.ReviewKind = [string]$review.kind
            $reviewedCount++
        }
        $reviewStatus = if ($reviewedCount -eq @($deduped).Count) { 'volledig' } else { 'gedeeltelijk' }
    }
    catch {
        $reviewStatus = 'mislukt'
        Write-Warning "Agentreview mislukt; regelscore en brontekst blijven beschikbaar: $($_.Exception.Message)"
    }
}

if ($RequireAgentReview -and $reviewStatus -ne 'volledig') {
    throw "Publicatie gestopt: agentreview is '$reviewStatus' ($reviewedCount/$(@($deduped).Count)) in plaats van volledig."
}

# Officiële bronnen, inhoudelijke wijzigingen, praktijktips en periodieke
# overzichten krijgen elk hun eigen leesroute. De oorspronkelijke bronsoort
# blijft daarnaast beschikbaar voor filtering en herkomst.
foreach ($item in $deduped) {
    if ($item.Channel -in @('official', 'tenant')) { $section = 'microsoft' }
    elseif ($item.Demote -eq 'digest') { $section = 'weekly' }
    elseif ($item.ReviewKind -in @('handleiding', 'naslag') -or $item.Demote -in @('guide', 'reference')) { $section = 'tips' }
    else { $section = 'changes' }
    $item | Add-Member -NotePropertyName Section -NotePropertyValue $section -Force
}

$tierRank = @{ action = 0; watch = 1; info = 2 }

$sorted = @($deduped |
    Sort-Object -Property @{ Expression = { $tierRank[$_.Tier] } },
                          @{ Expression = { $_.Score };     Descending = $true },
                          @{ Expression = { $_.Published }; Descending = $true })

foreach ($item in $sorted) {
    if (-not $state.ContainsKey($item.Id)) { $state[$item.Id] = $runStamp }
}

# State klein houden: alles ouder dan 180 dagen verdwijnt.
$stateCutoff = (Get-Date).ToUniversalTime().AddDays(-180)
$pruned      = @{}
foreach ($key in $state.Keys) {
    $seen = ConvertTo-DateTimeSafe ([string]$state[$key])
    if (-not $seen -or $seen -ge $stateCutoff) { $pruned[$key] = $state[$key] }
}
$pruned | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $StatePath -Encoding UTF8

#endregion

#region Agenda opbouwen -------------------------------------------------------

# Alles met een harde datum in de toekomst, op datum. Dit is de strook bovenaan
# het dashboard - de "VANAF 1 SEP" die je niet mag missen.
# De agenda is geen nieuwsoverzicht maar een lijst afspraken. Daarom alleen de
# harde soorten (deadline, stopt, vanaf) - een GA-release of losse vermelding
# hoort er niet in. Verzamelposts ook niet: die noemen andermans datums.
$agendaKinds = @($settings.agendaKinds)

$agendaCandidates = @($sorted |
    Where-Object {
        $_.KeyDate -and
        -not $_.Demote -and
        $_.KeyDate.kind -in $agendaKinds -and
        $_.KeyDate.urgency -ne 'past'
    } |
    Sort-Object @{ Expression = { $_.KeyDate.daysAway } }, @{ Expression = { $_.Score }; Descending = $true })

# Dezelfde post verschijnt op meerdere blogs onder een andere URL, dus ontdubbelen
# op titel: twee keer hetzelfde Ivanti-bericht in de strook is verspilde ruimte.
$agendaSeen = @{}
$agenda = @($agendaCandidates |
    Where-Object {
        $key = ($_.Title -replace '[^a-z0-9]', '').ToLowerInvariant()
        if ($key.Length -gt 60) { $key = $key.Substring(0, 60) }
        $key = "$key|$($_.KeyDate.iso)"

        if ($agendaSeen.ContainsKey($key)) { return $false }
        $agendaSeen[$key] = $true
        return $true
    } |
    Select-Object -First ([int]$settings.agendaMaxItems) |
    ForEach-Object {
        [PSCustomObject]@{
            id        = $_.Id
            title     = $_.Title
            titleEn   = $_.EnglishTitle
            link      = $_.Link
            source    = $_.Source
            tier      = $_.Tier
            date      = $_.KeyDate
            actionCtx = @($_.ActionCtx)
            actionCtxEn = @($_.EnglishActionCtx)
        }
    })

#endregion

#region HTML renderen ---------------------------------------------------------

$allCategories = @($sorted | ForEach-Object { $_.Categories } | Where-Object { $_ } |
                   Group-Object | Sort-Object Count -Descending |
                   ForEach-Object { [PSCustomObject]@{ name = $_.Name; count = $_.Count } })

$payload = [PSCustomObject]@{
    generated  = (Get-Date).ToString('dd-MM-yyyy HH:mm')
    today      = $today.ToString('yyyy-MM-dd')
    days       = $Days
    firstRun   = $isFirstRun
    duplicates = $duplicatesRemoved
    categories = $allCategories
    agenda     = $agenda
    feeds      = @($feedStatus | ForEach-Object {
        [PSCustomObject]@{
            Source = $_.Source
            Status = $_.Status
            Items = $_.Items
            Detail = $_.Detail
            kind = $(if ($_.Source -eq 'Artikelen verrijkt') { 'processing' } else { 'source' })
        }
    })
    review     = [PSCustomObject]@{
        status = $reviewStatus
        reviewed = $reviewedCount
        total = @($sorted).Count
    }
    thresholds = [PSCustomObject]@{
        watch = [int]$settings.watchThreshold
        action = [int]$settings.actionThreshold
        requiresActionSignal = [bool]$settings.requireActionSignal
    }
    interests = @($config.personalization.interests)
    sourceCatalog = @(
        @($config.feeds | Where-Object { $_.enabled -ne $false } | ForEach-Object {
            [PSCustomObject]@{
                name = $_.name
                channel = $(if ($_.tag -eq 'Microsoft') { 'official' } else { 'community' })
            }
        }) +
        @([PSCustomObject]@{ name = 'Message Center'; channel = 'tenant' })
    )
    items      = @($sorted | ForEach-Object {
        [PSCustomObject]@{
            id         = $_.Id
            title      = $_.Title
            titleEn    = $_.EnglishTitle
            originalTitle = $_.OriginalTitle
            link       = $_.Link
            source     = $_.Source
            alsoIn     = @($_.AlsoIn)
            tag        = $_.Tag
            date       = $_.Published.ToString('yyyy-MM-dd')
            dateText   = "$($_.Published.Day) $($dutchMonths[$_.Published.Month - 1])"
            summary    = $_.Summary
            summaryEn  = $_.EnglishSummary
            score      = $_.Score
            scoreBreakdown = @($_.ScoreBreakdown)
            tier       = $_.Tier
            keywords   = @($_.Keywords)
            actionCtx  = @($_.ActionCtx)
            actionCtxEn = @($_.EnglishActionCtx)
            demote     = $_.Demote
            categories = @($_.Categories)
            nativeTags = @($_.NativeTags)
            keyDate    = $_.KeyDate
            allDates   = @($_.AllDates)
            kind       = $_.Kind
            channel    = $_.Channel
            reviewKind = $_.ReviewKind
            agentReviewed = [bool]$_.AgentReviewed
            agentConfidence = $_.AgentConfidence
            agentReason = $_.AgentReason
            agentReasonEn = $_.AgentReasonEn
            section    = $_.Section
            enriched   = [bool]$_.Enriched
            isNew      = [bool]$_.IsNew
        }
    })
}

$json = $payload | ConvertTo-Json -Depth 8 -Compress
$json = $json -replace '</', '<\/'   # voorkomt dat data het script-blok vroegtijdig sluit

$templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src/index.template.html'
if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Template niet gevonden: $templatePath"
}

$template = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
$html     = $template.Replace('__DATA__', $json)
Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8

#endregion

#region Console-samenvatting --------------------------------------------------

$actionItems = @($sorted | Where-Object { $_.Tier -eq 'action' })
$newItems    = @($sorted | Where-Object { $_.IsNew })
$urgent      = @($agenda | Where-Object { $_.date.urgency -eq 'urgent' })

Write-Host ''
Write-Host "CTRL UPDATE  |  $($sorted.Count) items over $Days dagen" -ForegroundColor Cyan
Write-Host "  Actie: $($actionItems.Count)   Nieuw: $($newItems.Count)   Agenda: $($agenda.Count)   Dubbel verwijderd: $duplicatesRemoved"
Write-Host "  Agentreview: $reviewStatus ($reviewedCount/$($sorted.Count))"
Write-Host "  Dashboard: $OutputPath"

$failed = @($feedStatus | Where-Object { $_.Status -ne 'OK' })
if ($failed) {
    Write-Host ''
    Write-Host 'Bronnen met problemen:' -ForegroundColor Yellow
    $failed | Format-Table Source, Status, Detail -AutoSize | Out-String | Write-Host
}

if ($agenda) {
    Write-Host ''
    Write-Host 'Agenda - datums die eraan komen:' -ForegroundColor Magenta
    $agenda | Select-Object -First 10 |
        Format-Table @{ n = ''; e = { if ($_.date.urgency -eq 'urgent') { '!' } else { ' ' } }; width = 1 },
                     @{ n = 'Wanneer'; e = { "$($_.date.label) $($_.date.text)" }; width = 24 },
                     @{ n = 'Over';    e = { $_.date.relative }; width = 16 },
                     @{ n = 'Titel';   e = { $_.title } } |
        Out-String -Width 200 | Write-Host
}

if ($actionItems) {
    Write-Host ''
    Write-Host 'Actie-items:' -ForegroundColor Red
    $actionItems | Select-Object -First 10 |
        Format-Table @{ n = 'Score'; e = { $_.Score };                            width = 6  },
                     @{ n = 'Datum'; e = { $_.Published.ToString('yyyy-MM-dd') }; width = 11 },
                     @{ n = 'Bron';  e = { $_.Source };                           width = 24 },
                     @{ n = 'Titel'; e = { $_.Title } } |
        Out-String -Width 200 | Write-Host
}

if ($Open) { Start-Process $OutputPath }

#endregion
