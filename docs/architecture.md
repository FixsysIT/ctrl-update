# Architectuur

CTRL UPDATE gebruikt een eenvoudige, controleerbare statische publicatieketen:

```text
RSS / Atom / Message Center
            |
            v
scripts/Update-CtrlUpdate.ps1
  - normaliseren en ontdubbelen
  - regelscore en datumdetectie
  - optionele bronverrijking
            |
            v
scripts/Invoke-CtrlUpdateReview.ps1
  - tweetalige eindredactie
  - categorie en urgentie
  - cache op inhoudshash
            |
            v
src/index.template.html + JSON-payload
            |
            v
dist/index.html -> GitHub Pages -> news.intunetools.com
```

## Ontwerpkeuzes

- **Statisch bij uitlevering.** De browser ontvangt geen tokens en hoeft geen feeds rechtstreeks te benaderen.
- **Reviewcache op inhoudshash.** Alleen nieuwe of gewijzigde inhoud vraagt een nieuwe modelreview.
- **Fail-safe publicatie.** De laatst succesvolle `dist/index.html` blijft online als ophalen of reviewen mislukt.
- **Persoonlijke instellingen lokaal.** Filters, taal, leesstatus en triage staan in `localStorage`; er is geen gebruikersdatabase.
- **Git als audittrail.** Configuratie, cache, status en het gepubliceerde resultaat zijn per commit terug te vinden.

## Automatisering

De Pages-workflow publiceert uitsluitend gevalideerde wijzigingen aan `dist/`. Het ophalen en inhoudelijk reviewen gebeurt op een vertrouwde runner met een aangemelde Codex CLI; credentials worden nooit in de repository opgeslagen. Na een succesvolle generatie commit en pusht die runner alleen de gewijzigde data en publicatie-output.

Voor volledig cloud-native ophalen is een afzonderlijk API-credential als GitHub Actions-secret nodig. Activeer niet tegelijkertijd twee schrijvende refresh-runners: dat veroorzaakt onnodige commits en mergeconflicten.

## Foutgedrag

- Een mislukte bron wordt zichtbaar in de bronstatus, zonder de overige bronnen te blokkeren.
- Een mislukte agentreview mag nooit stilzwijgend als volledig beoordeeld worden gepubliceerd.
- Een mislukte kwaliteitscontrole of Pages-deployment laat de vorige productieversie intact.
