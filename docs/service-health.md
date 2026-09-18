# Microsoft 365 Service Health

CTRL UPDATE kan actieve Microsoft 365-incidenten uit de eigen tenant ophalen. De
officiele Microsoft Graph-route vereist tenant-authenticatie; dezelfde
tenantgerichte gegevens zijn niet anoniem beschikbaar.

## Beveiligingsmodel

- aparte single-tenant Entra-app voor uitsluitend CTRL UPDATE;
- alleen de Microsoft Graph-**application permission** `ServiceHealth.Read.All`;
- admin consent is vereist;
- GitHub Actions meldt zich aan met OIDC/workload identity federation;
- geen client secret, certificaat of gebruikersaccount in GitHub;
- de workflow weigert tokens met extra Microsoft Graph-rollen;
- de publieke site bevat alleen een generiek signaal met de getroffen dienst;
- issue-id, impacttekst en voortgangsupdates blijven in Microsoft 365 Service Health.

`ServiceMessage.Read.All` is niet nodig voor Service Health. Message Center is een
afzonderlijk feature-gated capability met eigen validatie en rollback; zie
[Message Center](message-center.md).

## Eenmalige tenantconfiguratie

1. Registreer in de bedoelde Entra-tenant een single-tenant-app, bijvoorbeeld
   `CTRL UPDATE Service Health`.
2. Voeg onder **API permissions > Microsoft Graph > Application permissions**
   uitsluitend `ServiceHealth.Read.All` toe en verleen admin consent.
3. Voeg onder **Certificates & secrets > Federated credentials** een GitHub
   Actions-credential toe voor repository `FixsysIT/ctrl-update` en branch `main`.
   Deze repository is na 15 juli 2026 gemaakt; gebruik daarom het door GitHub
   uitgegeven immutable OIDC-subject met owner- en repository-id, niet handmatig
   een oud naamgebaseerd subject:

   ```text
   repo:FixsysIT@69671703/ctrl-update@1375104146:ref:refs/heads/main
   ```
4. Voeg in GitHub onder **Settings > Secrets and variables > Actions > Variables**
   twee repository variables toe:

   - `CTRL_UPDATE_ENTRA_CLIENT_ID`: Application (client) ID van de app;
   - `CTRL_UPDATE_ENTRA_TENANT_ID`: Directory (tenant) ID.

Deze twee ids zijn configuratiewaarden en geen wachtwoorden. Maak geen
`CLIENT_SECRET` aan.

## Werking

De geplande GitHub-run vraagt een kortlevend OIDC-token aan, wisselt dit via
Microsoft Entra in en controleert dat het Graph-token exact
`ServiceHealth.Read.All` bevat. Daarna leest de pipeline:

```text
GET https://graph.microsoft.com/v1.0/admin/serviceAnnouncement/issues?$filter=isResolved eq false
```

Alleen actieve items met classificatie `incident` worden meegenomen. CTRL UPDATE
toont daarvoor een generieke kritieke waarschuwing en verwijst beheerders naar
`https://admin.cloud.microsoft/#/servicehealth` voor de afgeschermde details.
Zonder de twee GitHub-variables blijft de openbare nieuwsrefresh werken en wordt
Service Health bewust overgeslagen.

## Validatie en stopvoorwaarden

Voer eerst een handmatige GitHub-run uit. Ga alleen verder wanneer:

- OIDC-aanmelding slaagt zonder client secret;
- de tokencontrole exact één Graph-rol ziet: `ServiceHealth.Read.All`;
- de Service Health-bron `OK` meldt;
- geen issue-id of ruwe impacttekst in `dist/index.html` of de Git-history staat;
- Teams alleen het generieke incident en de link naar het admin center toont.

Stop bij `AADSTS`-fouten, een ontbrekende rol, extra Graph-rollen, een Graph 403 of
tenantdetails in de publieke output. Een generieke 403 bewijst niet welke
configuratie ontbreekt; controleer de echte fout voordat rechten worden gewijzigd.

## Terugdraaien

Verwijder de twee GitHub repository variables om de koppeling direct uit te
schakelen. Verwijder daarna desgewenst de federated credential, trek admin consent
in en verwijder de Entra-app. De RSS/Atom-nieuwsrefresh blijft onafhankelijk werken.
