# Intune Radar

Intune Radar maakt van tientallen Microsoft-, tenant- en vakblogbronnen één Nederlands, actiegericht overzicht.
De regelscore is volledig uitlegbaar; Codex verzorgt daarna de Nederlandse eindredactie en corrigeert de
inhoudelijke categorie en urgentie. Ongewijzigde artikelen worden via een inhoudshash uit de reviewcache gehaald.

## Dagelijks gebruiken

```powershell
.\Get-IntuneNews.ps1 -Open
```

Voor tenantberichten uit het Microsoft 365 Message Center:

```powershell
Connect-MgGraph -Scopes 'ServiceMessage.Read.All'
.\Get-IntuneNews.ps1 -Open
```

Zonder Graph-sessie blijven alle openbare bronnen werken en meldt het dashboard duidelijk dat Message Center niet is opgehaald.

Gebruik `-SkipAgentReview` als je bewust alleen de snelle regelscore en oorspronkelijke brontekst wilt genereren.

## Nieuws en blogs

Alles blijft in één radar, met zes weergaven:

- **Voor jou** gebruikt jouw gekozen onderwerpen en bronnen.
- **Microsoft & tenant** toont officiële Microsoft-bronnen en Message Center.
- **Wijzigingen & nieuws** toont inhoudelijke wijzigingen en nieuws van vakbloggers.
- **Praktijktips & gidsen** bevat handleidingen, uitleg en samengestelde blijvende tips.
- **Weekoverzichten** houdt verzamelposts en periodieke terugblikken apart.
- **Alles** is de volledige stroom.

Met de knop **EN/NL** wisselt de volledige radar van taal: interface, titels, samenvattingen,
actiepunten, agenttoelichting, datums en categorieën. De taalkeuze wordt per browser bewaard.

Via **Voorkeuren** kies je per browser onderwerpen en bronnen. Optionele domeinen zoals Veeam, Nutanix,
VMware/Omnissa en Windows 365/AVD staan standaard uit. Voorkeuren, leesstatus en beoordelingen worden in
`localStorage` van de huidige browser bewaard; ze synchroniseren niet automatisch naar een ander apparaat.

## Een blog toevoegen

Plak de gewone blog- of categorie-URL; het hulpscript zoekt en valideert de feed:

```powershell
.\Add-NewsSource.ps1 'https://voorbeeld.nl/blog/' -Name 'Voorbeeldblog'
```

Controleer het resultaat eerst zonder te schrijven met `-WhatIf`.

Een gebruiker kan in **Voorkeuren** ook een RSS-bron aanvragen en de voorkeuren als JSON exporteren. Valideer
en importeer zulke aanvragen centraal met:

```powershell
.\Import-IntuneRadarPreferences.ps1 .\intune-radar-voorkeuren.json -WhatIf
.\Import-IntuneRadarPreferences.ps1 .\intune-radar-voorkeuren.json
```

De browser haalt bewust niet rechtstreeks willekeurige RSS-feeds op: veel feeds blokkeren cross-origin-verzoeken,
en centrale validatie voorkomt kapotte, dubbele of onbetrouwbare bronnen.

Uitzonderlijk nuttige, tijdloze artikelen kunnen daarnaast in `curatedArticles` in `sources.json` worden
vastgezet. Ze blijven dan zichtbaar buiten het gewone nieuwsvenster van 14 dagen. De Remote Help-handleiding
van System Center Dudes is de eerste samengestelde praktijktip.

## Betekenis van de actielijst

`Actie` is een inhoudelijk beoordeeld signaal, maar nog steeds geen bewijs dat de wijziging jouw tenant raakt.
Open op iedere kaart de score-uitleg om de exacte broncorrectie, trefwoorden, datums en drempels te zien.
Beoordeel daarna de scope. Zet een relevant signaal op `Opvolging nodig` en bepaal vóór een brede wijziging
de doelgroep, een representatieve pilot, stopcriteria en het herstelpad. Test bij wijzigingen aan toegang
of authenticatie ook de afhankelijke aanmeldroutes en hersteltoegang.

De volledige ontwerp- en detectieregels staan in [EISEN.md](EISEN.md).
