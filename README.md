# CTRL UPDATE

[![Publiceer site](https://github.com/FixsysIT/ctrl-update/actions/workflows/pages.yml/badge.svg)](https://github.com/FixsysIT/ctrl-update/actions/workflows/pages.yml)
[![Controleer repository](https://github.com/FixsysIT/ctrl-update/actions/workflows/quality.yml/badge.svg)](https://github.com/FixsysIT/ctrl-update/actions/workflows/quality.yml)

CTRL UPDATE bundelt officiële Microsoft-updates, Message Center-berichten en zorgvuldig gekozen vakblogs in één actiegericht overzicht voor endpoint- en identitybeheerders.

**Productie:** [news.intunetools.com](https://news.intunetools.com/)

## Wat de radar doet

- haalt RSS- en Atom-bronnen op en kan optioneel Microsoft 365 Message Center meenemen;
- ontdubbelt berichten en groepeert officiële updates, nieuws, gidsen en weekoverzichten;
- scoort urgentie met uitlegbare regels;
- laat Codex titels, samenvattingen, categorieën en actiestatus inhoudelijk controleren;
- publiceert een zelfstandige statische pagina via GitHub Pages;
- bewaart taal, filters, leesstatus en persoonlijke onderwerpen uitsluitend in de browser.

Een automatische score is een signaal, geen bewijs dat een wijziging jouw tenant raakt. Controleer altijd scope, doelgroep, pilot, stopcriteria en herstelpad voordat je een wijziging uitvoert.

## Lokaal uitvoeren

Vereisten: PowerShell 7 en, voor de inhoudelijke review, een aangemelde Codex CLI.

```powershell
./scripts/Update-CtrlUpdate.ps1
```

De productieklare pagina wordt direct geschreven naar `dist/index.html`. Open hem na generatie met:

```powershell
./scripts/Update-CtrlUpdate.ps1 -Open
```

Zonder Codex-review kan een snelle diagnostische run worden uitgevoerd:

```powershell
./scripts/Update-CtrlUpdate.ps1 -SkipAgentReview -SkipMessageCenter
```

Voor tenantberichten is vooraf een Microsoft Graph-sessie nodig:

```powershell
Connect-MgGraph -Scopes 'ServiceMessage.Read.All'
./scripts/Update-CtrlUpdate.ps1
```

Zonder Graph-sessie blijven de openbare bronnen werken en meldt het dashboard dat Message Center niet is opgehaald.

## Bronnen beheren

Een blog- of categorie-URL wordt automatisch naar een bruikbare RSS/Atom-feed herleid en vóór opslag gevalideerd:

```powershell
./scripts/Add-CtrlUpdateSource.ps1 'https://voorbeeld.nl/blog/' -Name 'Voorbeeldblog' -WhatIf
./scripts/Add-CtrlUpdateSource.ps1 'https://voorbeeld.nl/blog/' -Name 'Voorbeeldblog'
```

Een gebruiker kan vanuit de radar voorkeuren en aangevraagde feeds exporteren. Importeer zo'n bestand eerst als proef:

```powershell
./scripts/Import-CtrlUpdatePreferences.ps1 ./ctrl-update-voorkeuren.json -WhatIf
```

Feedconfiguratie, trefwoorden en drempels staan in `config/sources.json`. Tijdloze, uitzonderlijk nuttige artikelen kunnen in `curatedArticles` worden vastgezet.

## Projectstructuur

```text
config/       bronnen, categorieën en scoringsregels
data/         state en herbruikbare reviewcache
docs/         functionele eisen en technische uitleg
schemas/      JSON-schema voor agentreview
scripts/      ophalen, reviewen, importeren en controleren
src/          HTML/CSS/JavaScript-brontemplate
dist/         exact wat GitHub Pages publiceert
.github/      kwaliteitscontrole en deployment
```

`dist/index.html` is bewust versiebeheerbaar: iedere online versie correspondeert daardoor met een concrete commit en kan eenvoudig worden teruggedraaid.

## Automatische refresh

GitHub Actions voert `.github/workflows/refresh.yml` dagelijks om 06:30 en 14:00 uit in `Europe/Amsterdam` (zomer- en wintertijd worden automatisch gevolgd). De workflow haalt de openbare bronnen op, laat alleen nieuwe of gewijzigde items door de officiële Codex GitHub Action beoordelen, valideert het resultaat en pusht uitsluitend gewijzigde cache-, state- en publicatiebestanden. Als een stap faalt wordt niets gepubliceerd en blijft de laatst geslaagde versie online.

De site toont bovenaan de laatste succesvolle publicatie en waarschuwt wanneer de data ouder is dan 26 uur. Teams ontvangt maximaal één Adaptive Card per run en uitsluitend bij een nieuw of gepromoveerd Actie-item, een gewijzigde harde actiedatum, een nieuwe bronstoring of een mislukte refresh. De versiebeheerbare nulmeting in `data/notification-state.json` voorkomt een eerste spamgolf en herhaalde meldingen.

De repository gebruikt hiervoor één verplichte en één optionele Actions-secret:

```text
OPENAI_API_KEY
TEAMS_WEBHOOK_URL  # optioneel; vereist voor Teams-meldingen
```

De OpenAI-sleutel wordt alleen rechtstreeks aan `openai/codex-action` aangeboden. De Teams-webhook wordt alleen aan de meldingsstap aangeboden. Geen van beide secrets wordt in een bestand of in de repository opgeslagen. Een ontbrekende of ongeldige Teams-koppeling blokkeert de nieuwsactualisatie niet. Message Center is niet onderdeel van deze publieke cloudrun omdat daarvoor tenantgebonden Microsoft Graph-authenticatie en afzonderlijk beheer van least-privilege credentials nodig zijn.

Een beheerder kan bij een handmatige workflowrun `teams_test` inschakelen. Na alle kwaliteitscontroles verstuurt die run precies één herkenbare testkaart en slaat de normale inhoudsmelding over. Geplande runs gebruiken deze testmodus nooit.

## Valideren

```powershell
./scripts/Test-CtrlUpdate.ps1
```

Deze controle parseert alle PowerShell en JSON, controleert bronduplicaten, valideert het reviewcacheformaat en verifieert dat de publicatie en cloudrefresh volledig geconfigureerd zijn. GitHub voert dezelfde controle uit vóór iedere Pages-deployment.

Meer achtergrond staat in [de architectuur](docs/architecture.md) en [de functionele eisen](docs/requirements.md).
