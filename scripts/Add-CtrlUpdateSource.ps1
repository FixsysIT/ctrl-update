<#
.SYNOPSIS
    Voegt een bron toe aan config/sources.json. Je plakt een gewone blog- of categorie-URL,
    het script zoekt zelf de bijbehorende RSS/Atom-feed.

.DESCRIPTION
    Zoekvolgorde:
      1. De URL is zelf al een feed.
      2. <link rel="alternate" type="application/rss+xml"> in de HTML (feed-autodiscovery).
         Zo vind je ook categoriefeeds: /category/intune/ wijst naar /category/intune/feed/.
      3. Gokken op de bekende paden: /feed/, /rss/, /atom.xml, /index.xml, /feeds/posts/default.

    De feed wordt gevalideerd (parsebaar en niet leeg) voordat hij wordt weggeschreven.

.PARAMETER Url
    De blog-, categorie- of feed-URL.

.PARAMETER Name
    Naam in het dashboard. Standaard de titel uit de feed zelf.

.PARAMETER Boost
    Vaste op- of aftrek bij de score van elk item uit deze bron. Negatief dempt ruis.

.PARAMETER Tag
    Vrij label, bijvoorbeeld Microsoft of Community. Standaard Community.

.PARAMETER WhatIf
    Laat zien wat er gevonden is zonder config/sources.json aan te passen.

.EXAMPLE
    .\scripts\Add-CtrlUpdateSource.ps1 https://www.systemcenterdudes.com/category/autopilot/

.EXAMPLE
    .\scripts\Add-CtrlUpdateSource.ps1 https://patchmypc.com/blog/ -Name 'Patch My PC' -Boost 1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Url,

    [string] $Name,
    [int]    $Boost = 0,
    [string] $Tag   = 'Community',
    [string] $ConfigPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/sources.json')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$config  = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$headers = @{
    'User-Agent'      = $config.settings.userAgent
    'Accept'          = 'application/rss+xml,application/xml,text/xml,text/html,*/*;q=0.8'
    'Accept-Language' = 'en-US,en;q=0.9'
}

function Get-Page {
    param([string]$Target)

    try {
        Invoke-WebRequest -Uri $Target -Headers $headers `
                          -TimeoutSec $config.settings.timeoutSec `
                          -MaximumRedirection 5 -UseBasicParsing
    }
    catch { return $null }
}

# Geeft de feedtitel terug als dit een bruikbare feed is, anders $null.
function Test-Feed {
    param([string]$Target)

    $response = Get-Page $Target
    if (-not $response) { return $null }

    $content = $response.Content -replace '^[﻿\s]+', ''
    if ($content -notmatch '^\s*<\?xml|^\s*<rss|^\s*<feed') { return $null }

    try   { $xml = [xml]$content }
    catch { return $null }

    if     ($xml.rss)  { $title = $xml.rss.channel.title; $count = @($xml.rss.channel.item).Count }
    elseif ($xml.feed) { $title = $xml.feed.title;        $count = @($xml.feed.entry).Count }
    else               { return $null }

    if ($title -is [System.Xml.XmlElement]) { $title = $title.InnerText }
    if ($title -match 'Resource Not Found') { return $null }
    if ($count -lt 1) { return $null }

    [PSCustomObject]@{ Url = $Target; Title = ([string]$title).Trim(); Items = $count }
}

Write-Host "Zoeken naar een feed op $Url" -ForegroundColor Cyan

# 1. Is dit zelf al een feed?
$found = Test-Feed $Url

# 2. Autodiscovery via de HTML.
if (-not $found) {
    $page = Get-Page $Url
    if ($page) {
        $links = [regex]::Matches(
            $page.Content,
            '<link[^>]+type=["\x27]application/(?:rss|atom)\+xml["\x27][^>]*>',
            'IgnoreCase')

        foreach ($link in $links) {
            $href = [regex]::Match($link.Value, 'href=["\x27]([^"\x27]+)["\x27]', 'IgnoreCase').Groups[1].Value
            if (-not $href) { continue }

            # Commentaarfeeds zijn nooit wat je zoekt.
            if ($href -match '/comments/feed|comments-feed') { continue }

            if ($href -notmatch '^https?://') {
                $href = ([uri]::new([uri]$Url, $href)).AbsoluteUri
            }

            Write-Verbose "Autodiscovery vond: $href"
            $found = Test-Feed $href
            if ($found) { break }
        }
    }
}

# 3. De bekende paden proberen.
if (-not $found) {
    $base = $Url.TrimEnd('/')
    foreach ($suffix in '/feed/', '/rss/', '/rss.xml', '/atom.xml', '/index.xml', '/feeds/posts/default') {
        Write-Verbose "Proberen: $base$suffix"
        $found = Test-Feed ($base + $suffix)
        if ($found) { break }
    }
}

if (-not $found) {
    Write-Host ''
    Write-Warning "Geen werkende feed gevonden op $Url"
    Write-Host 'Zoek de RSS-link handmatig op de site en voeg die met de volledige feed-URL toe.'
    return
}

if (-not $Name) { $Name = $found.Title }

Write-Host ''
Write-Host "  Feed   : $($found.Url)"
Write-Host "  Titel  : $($found.Title)"
Write-Host "  Items  : $($found.Items)"
Write-Host "  Naam   : $Name"
Write-Host "  Boost  : $Boost   Tag: $Tag"
Write-Host ''

$existing = $config.feeds | Where-Object { $_.url -eq $found.Url }
if ($existing) {
    Write-Warning "Deze feed staat er al in als '$($existing.name)'. Niets gewijzigd."
    return
}

if (-not $PSCmdlet.ShouldProcess($ConfigPath, "Bron '$Name' toevoegen")) { return }

# ConvertTo-Json van het hele configobject zou de opmaak en volgorde slopen, dus
# de nieuwe regel wordt in de tekst zelf voor de sluitende bracket geplakt.
$raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8

$entry = '    { "name": "' + ($Name -replace '"', '\"') + '", "url": "' + $found.Url +
         '", "boost": ' + $Boost + ', "tag": "' + $Tag + '" }'

$pattern = '(?s)("feeds"\s*:\s*\[.*?)(\r?\n\s*\])'
if ($raw -notmatch $pattern) { throw 'Kon het feeds-blok niet vinden in sources.json.' }

$updated = [regex]::Replace($raw, $pattern, {
    param($match)
    $match.Groups[1].Value + ",`r`n" + $entry + $match.Groups[2].Value
}, 1)

# Valideren voordat we het origineel overschrijven.
try   { $null = $updated | ConvertFrom-Json }
catch { throw "Resultaat is geen geldige JSON, sources.json niet aangepast: $($_.Exception.Message)" }

Set-Content -LiteralPath $ConfigPath -Value $updated -Encoding UTF8

Write-Host "Toegevoegd aan sources.json." -ForegroundColor Green
Write-Host "Draai .\scripts\Update-CtrlUpdate.ps1 -Open om het resultaat te zien."
