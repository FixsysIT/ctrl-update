# Microsoft 365 Message Center

CTRL UPDATE kan Message Center als afzonderlijke read-only tenantcapability
gebruiken. De eigen Microsoft 365-tenant is daarbij de referentietenant voor het
beheerde klantenportfolio.

## Toegang

- Microsoft Graph application permission `ServiceMessage.Read.All`;
- admin consent is vereist;
- dezelfde secretloze GitHub OIDC-identiteit kan worden gebruikt;
- andere Graph-rollen dan `ServiceHealth.Read.All` en `ServiceMessage.Read.All`
  worden door de workflow geweigerd;
- activering gebeurt pas met repositoryvariabele
  `CTRL_UPDATE_MESSAGE_CENTER_ENABLED=true`.

De runner leest via:

```text
GET https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/messages
```

De aanvraag gebruikt `$select` voor alleen titel, categorie, ernst, wijzigings- en
actiedatum, diensten, tags en berichttekst. Paginering volgt `@odata.nextLink` en
de bestaande periode- en dienstenfilters beperken de verwerkte berichten.

## Privacygrens

Ruwe berichttekst mag tijdelijk door de read-only agentreview worden verwerkt,
maar wordt niet gelogd, gecommit of gepubliceerd. De echte Message Center-id
wordt vóór state en cache vervangen door een SHA-256-afleiding. Publieke links
gaan uitsluitend naar het afgeschermde Message Center-startpunt.

De site publiceert alleen:

- afgeleide Nederlandse en Engelse titel en samenvatting;
- algemene urgentie;
- persoonlijke informatiewaarde voor de eigenaar;
- `Bevestigd in referentietenant`;
- actieerbaarheid, categorieën en een eventueel handelingsadvies.

## Gecontroleerde activering

1. Publiceer en valideer eerst de feature-gated code terwijl de variabele ontbreekt.
2. Voeg `ServiceMessage.Read.All` als application permission toe en verleen admin consent.
3. Zet `CTRL_UPDATE_MESSAGE_CENTER_ENABLED=true`.
4. Start één handmatige GitHub-run.
5. Stop wanneer de tokenrol ontbreekt, een onverwachte extra rol aanwezig is, Graph
   geen `200 OK` retourneert of ruwe Message Center-data in Git, logs of HTML staat.
6. Controleer minimaal één informatief bericht en één bericht met concrete actie of
   informatienood op urgentie, tenantrelevantie en actiestatus.

## Terugdraaien

Zet eerst `CTRL_UPDATE_MESSAGE_CENTER_ENABLED=false` of verwijder de variabele.
Daarna kan `ServiceMessage.Read.All` uit de Entra-app worden verwijderd. Service
Health en openbare bronnen blijven onafhankelijk werken.
