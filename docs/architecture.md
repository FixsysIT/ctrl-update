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

`.github/workflows/refresh.yml` draait dagelijks om 06:30 en 14:00 in `Europe/Amsterdam` volledig op een GitHub-hosted Linux-runner:

1. openbare bronnen ophalen en een lokale reviewinput maken;
2. dezelfde bronmomentopname vastleggen voor review en publicatie;
3. alleen nieuwe of inhoudelijk gewijzigde items selecteren;
4. die items via `openai/codex-action@v1` met een strikt JSON-schema beoordelen;
5. het resultaat atomair met de bestaande inhoudshash-cache samenvoegen;
6. de definitieve pagina uit exact dezelfde momentopname genereren en alle kwaliteitscontroles uitvoeren;
7. alleen nieuwe Actie-signalen, gewijzigde harde actiedatums en nieuwe bronstoringen als één Adaptive Card naar Teams sturen; brede incidenten en nood-/out-of-bandupdates krijgen daarin de aanduiding `Kritieke waarschuwing`;
8. alleen gewijzigde data, meldingsstatus en `dist/index.html` naar `main` pushen.

`OPENAI_API_KEY` en de optionele `TEAMS_WEBHOOK_URL` bestaan uitsluitend als GitHub Actions-secrets. De OpenAI-sleutel gaat direct naar de officiële Codex-action; de webhook alleen naar het meldingsscript. De Codex-stap draait read-only en behandelt alle artikeltekst als onbetrouwbare data. Een mislukte run pusht niets, zodat de vorige productieversie online blijft. Een ontbrekende of ongeldige webhook schakelt alleen de meldingen uit en blokkeert de nieuwsactualisatie niet.

`data/notification-state.json` is de auditeerbare nulmeting voor meldingen. Alle huidige items en bronstatussen worden bewaard, maar alleen de overgang naar `action`, een nieuw `action`-item, een gewijzigde harde datum of een nieuwe status `FOUT` veroorzaakt een kaart. Een actie met een gecontroleerd incident-signaal wordt als kritieke waarschuwing gepresenteerd. Bij een mislukte webhookpost wordt de nulmeting niet bijgewerkt, zodat de melding bij de volgende run opnieuw kan worden geprobeerd.

De daaropvolgende Pages-workflow valideert de commit opnieuw en publiceert uitsluitend `dist/`. Er mag maar één schrijvende refresh-runner actief zijn; lokale of tweede cloudtaken veroorzaken anders dubbele commits en mergeconflicten.

## Foutgedrag

- Een mislukte bron wordt zichtbaar in de bronstatus, zonder de overige bronnen te blokkeren.
- Een mislukte agentreview mag nooit stilzwijgend als volledig beoordeeld worden gepubliceerd.
- Een mislukte kwaliteitscontrole of Pages-deployment laat de vorige productieversie intact.
- Een ontbrekende of ongeldige API-secret laat de refresh vroeg falen zonder de website te wijzigen.
- Een mislukte refresh probeert een aparte technische Teams-kaart te sturen; een meldingsfout blokkeert de websitepublicatie niet.
