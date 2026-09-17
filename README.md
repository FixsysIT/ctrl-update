# Intune Radar

Intune Radar maakt van tientallen Microsoft- en communityfeeds één Nederlands, actiegericht overzicht.
Het dashboard werkt als los HTML-bestand en bewaart lees- en beoordelingsstatus alleen in de lokale browser.

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

## Een blog toevoegen

Plak de gewone blog- of categorie-URL; het hulpscript zoekt en valideert de feed:

```powershell
.\Add-NewsSource.ps1 'https://voorbeeld.nl/blog/' -Name 'Voorbeeldblog'
```

Controleer het resultaat eerst zonder te schrijven met `-WhatIf`.

## Betekenis van de actielijst

`Actie` is een automatisch signaal op basis van bronwoorden, score en concrete datums. Het is geen bewijs dat de wijziging jouw tenant raakt. Beoordeel daarom eerst de scope. Zet een relevant signaal op `Opvolging nodig` en bepaal vóór een brede wijziging de doelgroep, een representatieve pilot, stopcriteria en het herstelpad. Test bij wijzigingen aan toegang of authenticatie ook de afhankelijke aanmeldroutes en hersteltoegang; een geslaagde configuratiewijziging bewijst nog niet dat gebruikers hun resources bereiken.

De volledige ontwerp- en detectieregels staan in [EISEN.md](EISEN.md).
