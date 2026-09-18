# CTRL UPDATE - Eisen

Vastgelegd op 16-09-2026. Dit document is leidend: wijkt de code hiervan af, dan is de code fout.

## Waarom dit bestaat

Op 15-09-2026 kregen alle gebruikers in de tenant ineens een passkey-registratieprompt. Microsoft had dat
ruim zeven weken vooraf aangekondigd (Entra-blog 13-07-2026, Message Center, Entra admin center onder
"What's new"). Niemand had het gezien.

Het doel is niet volledigheid. Het doel is dat zoiets nooit meer onopgemerkt langskomt, zonder dat er
elke dag honderd berichten doorgespit moeten worden.

---

## Harde eisen

### T1 - Alles in het Nederlands
Alle interface-teksten, knoplabels, kolomkoppen, console-uitvoer, foutmeldingen, commentaar in de scripts
en documentatie zijn Nederlands.

**Uitzondering, bewust:** titels en samenvattingen van artikelen blijven in de taal van de bron. Vertalen
vereist een vertaal-API (Claude API of Azure Translator) en die zit er nu niet in. Zie Openstaand.

### T2 - Een datum moet eruit springen
Als een bericht een datum noemt waarop iets verandert, staat die datum groot en gekleurd bovenaan de
kaart, met label en aftelling: `VANAF 1 sep 2026 - loopt al 15 dagen`.

Labels worden afgeleid uit de woorden rond de datum, aan beide kanten:

| Label | Wanneer |
|---|---|
| `DEADLINE` | required by, no later than, before, until, prior to, uiterlijk |
| `STOPT` | retire, end of support, end of life, will be removed, sunset, vervalt |
| `VANAF` | starting, beginning, from, effective, as of, on or after, vanaf, per |
| `BESCHIKBAAR` | available, generally available, released, public preview |

### T3 - Wat nu loopt is urgenter dan wat later komt
Een wijziging die al is ingegaan staat bovenaan met `loopt al X dagen` in rood. De agenda kijkt
`agendaLookbackDays` (nu 45) terug, niet alleen vooruit. Dit was de kern van het passkey-probleem: op
16-09 was 1 september verleden tijd en dus onzichtbaar.

### T4 - Rood betekent: er moet iets gebeuren
Een item wordt alleen `Actie` als het allebei waar is:
1. score >= `actionThreshold`, en
2. er staat een actiewoord in (breaking change, retirement, deprecated, action required, enforced,
   mandatory, no opt out), er is een harde datum in de toekomst, of de bron beschrijft een bevestigde
   brede productiestoring of nood-/out-of-bandupdate die beheerders moeten beoordelen of uitrollen.

Een hoge score op losse onderwerpen is niet genoeg. Anders komt een certificerings-docpagina bovenaan
en wordt de rode lijst genegeerd.

### T5 - Bij elk rood item staat wat er moet gebeuren
Onder een rood item staat het blok "Waarom dit actie is" met maximaal drie zinnen **letterlijk uit de
bron**. Gekozen worden zinnen met een actiewoord, met de gevonden datum, of met een instructie
(you should, you must, make sure, we recommend, configure, migrate, before this date).

Er wordt niets samengevat of geparafraseerd. Wat er staat, staat er echt.

### T6 - De agenda bevat alleen afspraken
In "Wat er speelt" komen alleen datums van het soort `deadline`, `retirement` of `start`.
Niet: `available` (GA-releases, previews) en niet `mentioned` (datum zonder signaalwoord).

### T7 - Verzamelposts en handleidingen worden gedempt
Twee soorten posts noemen actiewoorden zonder dat er iets te doen is:

| Soort | Herkenning | Label |
|---|---|---|
| Verzamelpost | "What's new in...", "Intune Newsletter", "roundup", "In development" | `Verzamelpost` |
| Handleiding | "a practical guide", "how to", "from scratch", "step by step", "deep dive", "tutorial" | `Handleiding` |

Allebei:
- worden nooit rood (hooguit `Let op`),
- komen niet in de agenda.

De post die er echt over gaat staat los in de lijst en is wel rood. Zonder deze regel stond
"From GPO to Microsoft Intune: A practical guide" bovenaan de actielijst, puur omdat er ergens
`retire`, `deprecated` en `mandatory` in de lopende tekst stond.

Let op: de herkenning gaat op de titel. Een how-to met een titel die er niet op lijkt ("Remove Any
Preinstalled Microsoft Store App with Intune Settings Catalog") glipt erlangs. Term toevoegen aan
`digest.guideTerms` in `config/sources.json` lost dat op.

### T8 - Eigen bronnen toevoegen zonder RSS te zoeken
`.\scripts\Add-CtrlUpdateSource.ps1 <url>` accepteert een gewone blog- of categorie-URL en vindt de feed zelf, via
feed-autodiscovery in de HTML en anders door de bekende paden af te lopen. Categoriefeeds werken:
`https://www.systemcenterdudes.com/category/intune/` wordt `/category/intune/feed/`.

De feed wordt eerst gevalideerd (parsebaar, niet leeg, geen "Resource Not Found") en `config/sources.json` wordt
alleen weggeschreven als het resultaat geldige JSON is.

### T9 - Categorieen
Elk item krijgt maximaal drie categorieen uit de vaste lijst in `config/sources.json` (Autopilot, Enrollment,
Compliance, Conditional Access, Identiteit & MFA, Defender & Security, Windows Update, Apps & Packaging,
Scripting & Graph, Windows 11, macOS, iOS & iPadOS, Android, Licensing, Reporting). Die zijn klikbaar
als filter.

Daarnaast worden de rubrieken van de bron zelf getoond als `#tag`. Die verschillen per site en zijn
daarom geen filter, maar zetten wel de zoekterm.

### T10 - Een stille bron moet opvallen
Onderaan staat per bron de status en het aantal items. Een bron die niets oplevert of faalt is
zichtbaar, zodat een kapotte feed niet jarenlang stil blijft. Dit is hoe het verkeerde board-id van
Intune Customer Success gevonden is.

### T11 - Nieuw sinds vorige run klopt
`data/state.json` onthoudt 180 dagen welke items gezien zijn. Twee keer op een dag draaien levert niet
twee keer dezelfde "Nieuw"-labels op.

### T12 - Scoren op de hele tekst, tonen op een fragment
Scoren gebeurt op `scoreTextLength` (6000) tekens, tonen op `summaryLength` (320). Anders valt een
"will be retired" halverwege de post buiten beeld.

Levert een feed maar een fragment, dan wordt de artikelpagina zelf opgehaald (`enrich`, maximaal
`maxPages` per run). Dat is de enige trage stap.

### T13 - Geen valse datums
- Datums gelijk aan de publicatiedatum van het item tellen niet mee (dat is de byline).
- Een maand zonder dag telt alleen mee als er een signaalwoord bij staat.
- Buiten het venster van 90 dagen terug tot 4 jaar vooruit: weg.

### T14 - Een actiesignaal krijgt een menselijke status
Een rood item begint als `Te beoordelen`. De beheerder kan het lokaal markeren als `Opvolging nodig`,
`Afgehandeld` of `Niet van toepassing`. De keuze blijft in de browser bewaard. Het ochtendoverzicht
toont apart hoeveel signalen nog beoordeeld moeten worden en hoeveel bevestigde acties opvolging vragen.

Een automatische score is nadrukkelijk geen bewijs van tenantimpact. Voor uitvoering wordt minimaal
de doelgroep, een representatieve pilot, een stopcriterium en een herstelpad bepaald. Bij wijzigingen
aan toegang of authenticatie worden ook de afhankelijke aanmeldroutes en hersteltoegang getest.

### T15 - Naslag is geen actie zonder wijzigingsdatum
Zoekresultaten uit Learn Docs zijn vaak bestaande handleidingen of naslag. Als zo'n pagina geen concrete
wijzigingsdatum bevat, wordt deze als `Naslag` gedempt en nooit rood. Dit voorkomt dat instructiewoorden
zoals `enable` of `enforce` een bestaande configuratiepagina tot wijzigingsmelding verheffen.

---

## Vormgeving

Ontleend aan hoe alert- en nieuwsdashboards dit oplossen (PatternFly status- en severity-patronen,
feed-UX rond scanbaarheid en dichtheid).

### V1 - Kleur draagt nooit alleen de betekenis
Elke urgentie heeft een kleur **plus** een icoon **plus** een woord. Wie kleur slecht onderscheidt,
leest het nog steeds. Iconen per datumsoort: klok = `DEADLINE`, blokje = `STOPT`, driehoek = `VANAF`,
ster = `BESCHIKBAAR`.

### V2 - Kleurbetekenis ligt vast
| Kleur | Betekenis |
|---|---|
| Rood | Actie, of een wijziging die nu loopt |
| Oranje | Let op |
| Blauw | Ingepland, datum ver weg |
| Groen | Alles rustig (alleen in de statusbalk) |
| Grijs | Informatief, gedempt |

Groen werd eerst ook voor geplande datums gebruikt. Dat leest als "afgehandeld", terwijl een deadline
over 137 dagen gewoon nog moet gebeuren. Ingepland is nu blauw; groen betekent alleen nog "niets te doen".

### V3 - Eén regel bovenaan beantwoordt de enige vraag die telt
De statusbalk zegt of er nu iets moet gebeuren, zoals een statuspagina dat doet. Drie toestanden:
rood (er loopt iets of er is een datum binnen drie weken), oranje (er zijn actie-items, geen harde
datum dichtbij), groen (niets dringend).

### V4 - Belangrijkste informatie het meest links
Lezers scannen in een F-patroon. Daarom is de linkerrand van een kaart de urgentiebalk, niet de
publicatiedatum. Die datum stond eerst op de opvallendste plek terwijl hij het minst zegt.

### V5 - Twee volgordes, want er zijn twee vragen
- **Urgentie** (standaard): wat moet ik doen, gesorteerd op tier en score.
- **Tijdlijn**: wat is er gebeurd, chronologisch met sticky dagkoppen (Vandaag, Gisteren, wo 10 sep).

### V6 - Dichtheid instelbaar
Ruim (~48px per rij) voor lezen, compact (~36px) voor scannen. Compact verbergt de samenvattingen.
Keuze blijft bewaard.

### V7 - Toetsenbord
`j`/`k` navigeren, `o` openen, `m` gelezen, `e` uitleg klappen, `/` zoeken, `a` alleen acties,
`r` filters wissen, `?` hulp. Zonder muis doorheen kunnen is het verschil tussen dagelijks gebruiken
en niet gebruiken.

### V8 - Lange lijst wordt niet in één keer getekend
Dertig items per keer, daarna "Nog N items tonen". Categorieen in de zijbalk klappen in na negen.

### V9 - Randvoorwaarden
- Licht en donker, volgt het systeem, knop om te forceren, keuze blijft bewaard.
- Geen horizontale scroll op telefoonbreedte; filters verhuizen daar achter een knop.
- Eén bestand, geen externe scripts of fonts, werkt offline.

---

## Niet doen

- Geen items verzinnen, samenvatten of interpreteren die niet in de bron staan.
- Geen bron stilletjes laten wegvallen.
- Niet alles rood maken. Als de rode lijst niet klopt wordt hij niet gelezen, en dan mislukt het doel.
- Geen cloudafhankelijkheid voor de basis. Blogs lezen moet werken zonder Graph-sessie.

---

## Openstaand

| Punt | Waarom nog niet |
|---|---|
| Message Center cloudactivering | Implementatie is feature-gated voorbereid; admin consent voor `ServiceMessage.Read.All`, repositoryvariabele en live privacyvalidatie ontbreken nog. |
| Meerdere klanttenants | Message Center is nu een tenant. Voor meerdere klanten is app-only auth per tenant nodig. |

## V12 - Veilige automatische actualisatie

- GitHub Actions draait dagelijks om 06:30 en 14:00 in `Europe/Amsterdam`, inclusief zomertijd.
- Ieder gepubliceerd item moet een volledige agentreview hebben. Alleen ongewijzigde
  inhoud met dezelfde reviewbeleidsversie mag een eerdere agentreview uit de cache
  hergebruiken; nieuwe of gewijzigde inhoud en gewijzigd beleid gaan opnieuw langs de agent.
- Parsing, schema-validatie, agentreview en de netwerkloze repositorytest zijn verplichte publicatiepoorten.
- Een volledige migratie wordt opgesplitst in begrensde agentbatches; alle batches
  moeten slagen en atomair samenvoegen voordat publicatie mogelijk is.
- Een mislukte run commit en publiceert niets; de laatst geslaagde GitHub Pages-versie blijft online.
- De kop toont de laatste succesvolle publicatie en een zichtbare waarschuwing na 26 uur zonder succes.
- Teams ontvangt alleen nieuwe of gepromoveerde Actie-items, gewijzigde harde actiedatums, nieuwe bronstoringen en mislukte refreshes. Let op-, Info-, blog- en weekitems veroorzaken geen melding. Een bevestigd breed incident of een nood-/out-of-bandupdate wordt als `Kritieke waarschuwing` gemarkeerd.
- Per run wordt maximaal één Adaptive Card gestuurd. De bestaande dataset is de nulmeting en veroorzaakt geen eerste spamgolf; ongewijzigde signalen worden niet opnieuw gemeld.

## V10 - Agent-eindredactie, kanalen en persoonlijke radar

- Codex beoordeelt ieder artikel inhoudelijk en schrijft titel, samenvatting en actiepunten in het Nederlands.
- Inhoudshash plus reviewbeleidsversie voorkomen dubbele modelcalls zonder een oud
  agentoordeel na gewijzigde regels te hergebruiken; `data/review-cache.json` is de cache.
- De regelscore blijft zichtbaar en uitlegbaar. De agent mag een trefwoordfoutpositief terugzetten naar informatie.
- Eén stroom blijft de bron van waarheid, met weergaven voor Voor jou, Microsoft & tenant, Vakblogs en Alles.
- Onderwerp- en bronkeuzes zijn per browser. Optionele domeinen staan standaard uit.
- Een RSS-aanvraag uit de browser wordt geëxporteerd en daarna centraal ontdekt en gevalideerd. De statische
  browserpagina is bewust geen open RSS-proxy.
- Ieder item toont afzonderlijk algemene urgentie, tenantrelevantie, persoonlijke
  informatiewaarde en persoonlijke actiestatus. De agent kent `Moet je zien`,
  `Relevant`, `Achtergrond` of `Lage relevantie` toe; regelscore, bronsoort en
  populariteit mogen dit oordeel niet vervangen. Actiestatus kent `Te beoordelen`, `Opvolgen`, `Gepland`, `Afgerond`
  en `Niet van toepassing` en blijft browserlokaal.
- Tenantgerichte Service Health- en Message Center-signalen zijn `Bevestigd in
  referentietenant`; dit is geen bewijs van impact in iedere klantconfiguratie.

## V11 - Tweetalig, inhoudsroutes en blijvende praktijktips

- EN/NL wisselt zowel de interface als alle agentredactie; productnamen blijven onvertaald.
- Microsoft/tenant, wijzigingen, praktijktips en weekoverzichten zijn aparte routes binnen dezelfde dataset.
- De agentclassificatie bepaalt de route per artikel; de naam van de website alleen is niet genoeg.
- `curatedArticles` bewaart uitzonderlijk nuttige handleidingen buiten het nieuwsvenster.
- Op desktop heeft de linker filterkolom een eigen viewport-scroll, zodat categorieën bereikbaar blijven
  zonder eerst de lange rechter nieuwslijst naar beneden te hoeven scrollen.

---

## Bestanden

| Bestand | Rol |
|---|---|
| `scripts/Update-CtrlUpdate.ps1` | Ophalen, scoren, datums herkennen, dashboard schrijven |
| `scripts/Invoke-CtrlUpdateReview.ps1` | Nederlandse Codex-eindredactie met cache en schema-validatie |
| `scripts/New-CtrlUpdateReviewBatch.ps1` | Selecteert nieuwe of gewijzigde items voor cloudreview |
| `scripts/Merge-CtrlUpdateReview.ps1` | Valideert en combineert cloudreview atomair met de cache |
| `scripts/Add-CtrlUpdateSource.ps1` | Bron toevoegen vanaf een gewone URL |
| `scripts/Import-CtrlUpdatePreferences.ps1` | Geëxporteerde RSS-aanvragen valideren en importeren |
| `scripts/Test-CtrlUpdate.ps1` | Netwerkloze repository- en publicatiecontroles |
| `schemas/review.schema.json` | Strikt uitvoerschema voor de agentreview |
| `data/review-cache.json` | Reviewcache op inhoudshash |
| `config/sources.json` | Feeds, categorieen, trefwoorden en drempels |
| `src/index.template.html` | Vormgeving, los van de logica |
| `dist/index.html` | De publicatie voor GitHub Pages |
| `data/state.json` | Wat al gezien is |

## Testen

```powershell
# Datumherkenning op een enkele pagina, zonder hele run
.\scripts\Update-CtrlUpdate.ps1 -TestUrl 'https://learn.microsoft.com/en-us/entra/identity/authentication/concept-sms-voice-retirement'
```

Deze pagina is de vaste acceptatietest. Verwacht op 17-09-2026: vier datums (1 sep 2026 STOPT,
18 sep 2026 genoemd, 1 feb 2027 STOPT en 1 jul 2027 STOPT), actie-signaal waar en categorie
Identiteit & MFA. Microsoft kan de pagina later aanpassen; behandel een afwijking als inhoudelijke
review, niet automatisch als testfout.
