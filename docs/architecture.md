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

`.github/workflows/refresh.yml` draait iedere vier uur volledig op een GitHub-hosted Linux-runner:

1. openbare bronnen ophalen en een lokale reviewinput maken;
2. alleen nieuwe of inhoudelijk gewijzigde items selecteren;
3. die items via `openai/codex-action@v1` met een strikt JSON-schema beoordelen;
4. het resultaat atomair met de bestaande inhoudshash-cache samenvoegen;
5. de definitieve pagina genereren en alle kwaliteitscontroles uitvoeren;
6. alleen gewijzigde data en `dist/index.html` naar `main` pushen.

`OPENAI_API_KEY` bestaat uitsluitend als GitHub Actions-secret en wordt direct aan de officiële Codex-action doorgegeven. De repositoryscripts ontvangen de sleutel niet. De Codex-stap draait read-only en behandelt alle artikeltekst als onbetrouwbare data. Een mislukte run pusht niets, zodat de vorige productieversie online blijft.

De daaropvolgende Pages-workflow valideert de commit opnieuw en publiceert uitsluitend `dist/`. Er mag maar één schrijvende refresh-runner actief zijn; lokale of tweede cloudtaken veroorzaken anders dubbele commits en mergeconflicten.

## Foutgedrag

- Een mislukte bron wordt zichtbaar in de bronstatus, zonder de overige bronnen te blokkeren.
- Een mislukte agentreview mag nooit stilzwijgend als volledig beoordeeld worden gepubliceerd.
- Een mislukte kwaliteitscontrole of Pages-deployment laat de vorige productieversie intact.
- Een ontbrekende of ongeldige API-secret laat de refresh vroeg falen zonder de website te wijzigen.
