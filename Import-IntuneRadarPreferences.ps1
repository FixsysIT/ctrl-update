<#
.SYNOPSIS
    Importeert de RSS-bronaanvragen uit een geëxporteerd voorkeurenbestand.

.DESCRIPTION
    Elke aangevraagde website- of feed-URL gaat door Add-NewsSource.ps1. Dat script
    zoekt RSS/Atom op, valideert dat de feed parsebaar en niet leeg is en schrijft
    hem pas daarna naar sources.json. Persoonlijke onderwerp- en bronfilters blijven
    browserinstellingen en worden niet centraal overgenomen.

.EXAMPLE
    .\Import-IntuneRadarPreferences.ps1 .\intune-radar-voorkeuren.json -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Path,
    [int]    $Boost = 0,
    [ValidateSet('Community', 'Microsoft')]
    [string] $Tag = 'Community',
    [string] $ConfigPath = (Join-Path $PSScriptRoot 'sources.json')
)

$ErrorActionPreference = 'Stop'
$packet = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
$preferences = if ($packet.preferences) { $packet.preferences } else { $packet }
$requests = @($preferences.requestedFeeds)

if ($requests.Count -eq 0) {
    Write-Host 'Dit bestand bevat geen RSS-bronaanvragen.' -ForegroundColor Yellow
    return
}

Write-Host "$($requests.Count) RSS-bronaanvragen gevonden." -ForegroundColor Cyan
foreach ($request in $requests) {
    if ([string]::IsNullOrWhiteSpace([string]$request.url)) { continue }
    $name = if ([string]::IsNullOrWhiteSpace([string]$request.name)) { $null } else { [string]$request.name }

    if ($PSCmdlet.ShouldProcess([string]$request.url, 'RSS-bron ontdekken, valideren en toevoegen')) {
        & (Join-Path $PSScriptRoot 'Add-NewsSource.ps1') `
            -Url ([string]$request.url) -Name $name -Boost $Boost -Tag $Tag -ConfigPath $ConfigPath
    }
}
