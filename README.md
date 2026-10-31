# gptom_aidl_plugin

Flutter-Plugin zur Anbindung der [GP tom](https://www.gptom.com) App (Global
Payments SoftPOS) aus der eigenen App heraus – Kartenzahlungen, Storno,
Rückerstattung, Kassenschnitt, Anmeldung (Login, Logout, Passwortwechsel,
Morgen-Check) und Status.

| Plattform | Anbindung | Umfang |
|---|---|---|
| Android (minSdk 26) | app2app **AIDL** (`com.gptom.app2app:aidl` 1.29.0) | Sale, Void, Refund, Close Batch, Status, Details, Login, Logout, Passwortwechsel |
| iOS | **URL-Scheme** `gptom://` + Redirect | Sale, Void, Refund, Close Batch, Belegabfrage, Status, Login, Logout, Passwortwechsel |

Alle Geldbeträge sind durchgängig **`int` in Cent** (`1111` = 11,11 EUR).
Für Anzeigen gibt es `...Euro`-Getter.

## Installation

```yaml
dependencies:
  gptom_aidl_plugin:
    git:
      url: https://github.com/mhmmdlkts/gptom_aidl_plugin.git
```

### Android

Kein zusätzliches Setup nötig. Das Plugin bringt die `<queries>`-Einträge für
die GP tom Packages (`com.globalpayments.atom` bzw. `.dev`) mit und bindet
die Services selbst. Voraussetzung: GP tom App ist installiert und ein
Benutzer ist angemeldet.

### iOS

1. In der `Info.plist` das GP tom Scheme freigeben:

```xml
<key>LSApplicationQueriesSchemes</key>
<array>
  <string>gptom</string>
</array>
```

2. Ein eigenes URL-Scheme registrieren (darüber liefert GP tom das Ergebnis
zurück), z. B. `meineapp`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>meineapp</string>
    </array>
  </dict>
</array>
```

3. Beim `bindService` dieses Scheme übergeben (`uriSchemeIOS: 'meineapp'`).

4. Den Redirect-Listener schon beim App-Start registrieren (`initState`):

```dart
GptomAidlPlugin().listenIOS('meineapp');
```

Beendet iOS die App, während GP tom im Vordergrund ist, kommt der Redirect
beim Kaltstart an. Lauscht dann niemand, ist die Zahlung für die Kasse
spurlos verschwunden – siehe [Offene Zahlungen nach einem Kaltstart](#offene-zahlungen-nach-einem-kaltstart).

## Verwendung

### Verkauf (Sale)

```dart
final plugin = GptomAidlPlugin();

// einmalig
await plugin.bindService(uriSchemeIOS: 'meineapp'); // Scheme nur für iOS relevant

// Android braucht vor jeder Transaktion eine Registrierung:
String? transactionId;
if (Platform.isAndroid) {
  final register = await plugin.registerTransactionV2Android();
  if (!register.isSuccess) {
    // Fehler behandeln (register.resultCode / register.error)
    return;
  }
  transactionId = register.transactionId;
}

final result = await plugin.sell(
  transactionIdAndroid: transactionId,
  amountCents: 1250, // 12,50 EUR
  transactionMethode: TransactionMethode.card,
  referenz: 'RE-2026-001', // eigene Kennung, max. 20 Zeichen
  timeout: const Duration(minutes: 4),
  tipAmountCents: 100,
  preferableReceiptType: PreferableReceiptType.email,
  clientInfo: {
    'email': 'kunde@example.com',
    'phone': '+436601234567',
  },
);

if (result.result == GptomResultCode.success) {
  // Erfolgreich – result.approvedCode, result.cardNumber (maskiert), ...
} else if (GptomResultCode.istUnklar(result.result)) {
  // Die Karte KANN belastet sein: nachfragen, niemals wiederholen.
} else if (GptomResultCode.istOhneBelastung(result.result)) {
  // Sicher nichts abgebucht (nicht geöffnet / abgebrochen) – wiederholbar.
} else {
  // Ablehnung des Terminals; result.error?.errorMessage beschreibt sie.
}
```

`clientInfo` nimmt die flachen Keys `email`/`phone` entgegen; das Plugin
wandelt sie in die von GP tom erwartete `contact`-Struktur um.

`referenz` ist die eigene Kennung der Zahlung (z. B. die Rechnungsnummer,
höchstens 20 Zeichen). Auf iOS ordnet das Plugin den Redirect darüber der
richtigen Zahlung zu; ohne Angabe wird eine erzeugt
(`GptomAidlPlugin.neueReferenz()`).

`timeout` begrenzt das Warten auf beiden Plattformen (iOS: Redirect,
Standard 3 Minuten; Android: nativer Wächter auf `requestTransactionV2`,
Standard 240 Sekunden). Läuft die Frist ab, kommt `-1003` – die Karte kann
dann belastet sein.

### Ergebnis einordnen

Nach einer Kartenzahlung gibt es drei Lager, und nur eines davon darf
wiederholt werden:

| | Codes | Was die App tun muss |
|---|---|---|
| Erfolg | `0` | Beleg schreiben |
| Unklar (`GptomResultCode.istUnklar`) | `-1001`, `-1003`, `-1004`, `-1005`, `-1007` | Nachfragen (Android: `stateRequestAndroid`/`inquireTransactionAndroid`, iOS: `pendingRedirect`, `transactionDetailIOS`), **nie** neu belasten |
| Sicher ohne Belastung (`istOhneBelastung`) | `-1002`, `-1006` | Gefahrlos wiederholbar |
| Ablehnung | `-1` … `-9` | Grund anzeigen, wiederholbar |
| Nicht gestartet (Android, Ausnahme) | `PlatformException(code: 'UNTRUSTED_APP')` | Nichts belastet: die Signaturprüfung der GP tom App schlug fehl, die Zahlung lief gar nicht erst an. Erst die App klären (`checkGpTomApp`, siehe [Signaturprüfung](#signaturprüfung-android)), dann wiederholen |

`UNTRUSTED_APP` werfen `sell`, `voidSell`, `refund`, `closeBatch` und
`requestTransactionV2Android` auf Android, solange `openGptomUI` an ist
(Standard). Die Kasse muss diese Ausnahme abfangen.

### Späte Antwort nach Zeitablauf (Android)

Antwortet GP tom erst nach dem Wächter-Timeout, ist der Aufruf längst mit
`-1003` beantwortet. Das echte Ergebnis geht dann über einen eigenen Strom:

```dart
plugin.lateTransactionResultStream.listen((result) {
  // result.transactionId / result.result – nachträglich auflösen
});
```

### Offene Zahlungen nach einem Kaltstart

Ein Redirect, für den es keinen wartenden Aufruf gab (Kaltstart oder ein
verspäteter Redirect der Vorzahlung), geht in einen Puffer statt verloren.
Die Kasse holt ihn mit der **vor der Zahlung gespeicherten** `requestId` ab:

```dart
// vor der Zahlung (iOS): erzeugen und sichern, dann erst bezahlen
final requestId = GptomAidlPlugin.neueVorgangsId();
await speicher.schreibe('offene_zahlung', requestId);
await plugin.sell(/* ... */ requestId: requestId);

// nach dem Kaltstart
final gespeichert = await speicher.lese('offene_zahlung');
final offen = plugin.pendingRedirect(requestId: gespeichert);
if (offen != null && offen.isVerified) {
  final ergebnis = offen.asSellResult();
  // ergebnis.result, ergebnis.transactionId, offen.status
} else {
  // kein Redirect (oder unbestätigt): beim Terminal nachfragen
  // (per requestId nur mit sendRequestIdIOS, sonst amsId angeben)
  final beleg = await plugin.transactionDetailIOS(requestId: gespeichert);
  // beleg.result == 0: Beleg gefunden; -1004: kein Beleg, Ausgang weiter unklar
}
```

`pendingRedirect(originReferenceNum: ...)` gibt es weiterhin, bestätigt aber
nur Redirects, deren Token in diesem Prozess für eine noch offene Zahlung
vergeben wurde; nach einem Kaltstart ist der Redirect damit unbestätigt
(`-1007`). Ohne Angabe (und bei mehreren Treffern zur Referenz) kommt
**zuerst der älteste bestätigte** Eintrag, erst wenn es keinen gibt der
älteste unbestätigte – eine Fälschung verdeckt so nie die echte Antwort. Ist
der Puffer voll (10 Einträge), fallen zuerst unbestätigte heraus.
`plugin.pendingRedirects` zeigt alle, ohne sie zu entfernen.

In den Puffer kommen nur Redirects, die eine Zahlung sein können: Späte
Redirects von Status, Login, Logout, Passwortwechsel, Kassenschnitt und
Belegabfrage verwirft das Plugin (sie stehen nur im Rohstrom). Schickt GP tom
einen schon beantworteten oder abgeholten Redirect ein zweites Mal, ist die
Kopie unbestätigt (`-1007`), auch über `pendingRedirect(requestId:)`.
Mehr dazu unter [Sicherheit](#sicherheit).

### Status & Details (nur Android)

```dart
final state = await plugin.stateRequestAndroid(transactionId);
// state.state: created, started, inProgress, completed, cancelled, error, ...
// state.state.isRepeatable: gleiche transactionId erneut verwenden?

final details = await plugin.inquireTransactionAndroid(transactionId);
// details.amountCents, details.cardNumber, details.approvedCode, ...
```

Laut GP tom Doku gilt: bleibt eine Transaktion länger als 5 Minuten in
`IN_PROGRESS`, sollte sie als fehlgeschlagen behandelt werden.

### Storno / Rückerstattung / Kassenschnitt

```dart
await plugin.voidSell(
  transactionIdAndroid: neueRegistrierteId, // Android
  originTransactionId: original.transactionId!,
  cancelMode: CancelMode.last, // last = letzte, older = ältere Transaktion
);

await plugin.refund( // Android und iOS
  transactionIdAndroid: neueRegistrierteId,
  originTransactionId: original.transactionId, // optional: ohne = Rückerstattung ohne Bezug
  amountCents: 500,
);

final batch = await plugin.closeBatch(transactionIdAndroid: neueRegistrierteId);
// Android: RequestResult, iOS: Batch (inkl. subBatches je Zahlungsart)
```

### Login-Service (nur Android, alte Methoden)

`bindLoginService`, `loginGpTom`, `logoutGpTom`, `changeGpTomPassword` und
`loginStatusStream` bleiben aufrufbar, die drei Aktionen sind aber
`@Deprecated`: Sie schicken nur ab, das Ergebnis kommt irgendwann im Stream.
Neu: `login()`, `logout()`, `changePassword()` und `ensureLoggedIn()` – siehe
[Anmeldung & Status](#anmeldung--status-android-und-ios).

## Anmeldung & Status (Android und iOS)

Die Kasse hält die GP-tom-Zugangsdaten selbst und reicht sie nur für den
Login herein. Das Plugin speichert sie nicht. Zur Ablage eignet sich
`flutter_secure_storage` (Keychain/Keystore), nicht `SharedPreferences`.

```dart
final status = await plugin.getStatus();
// status?.loginState: loggedIn, loggedOut, unverifiedLoggedIn, unknown

final result = await plugin.login(
  GptomCredentials(
    username: 'livia@melisse-nails.example',
    password: passwort,
    terminalId: '12345678',
  ),
);
// result.outcome, result.rawStatus, result.rawError
```

`login()`, `logout()` und `changePassword()` warten auf den Ausgang
(`GptomLoginResult.outcome`, Standard 60 s) statt nur abzuschicken. Es läuft
immer nur eine Konto-Operation zur Zeit, jede weitere ergibt `busy`.

### Genius Pay öffnen

```dart
final geoeffnet = await plugin.openApp(); // false: nicht möglich, wirft nie
```

Öffnet den Startbildschirm der App, z. B. damit der Fahrer deren Meldung
sieht. Android prüft vorher die Signatur wie beim Zahlungsstart.

### Morgen-Check

`ensureLoggedIn()` prüft die GP tom App und den Status und meldet nur an,
wenn GP tom abgemeldet ist. Die Zugangsdaten werden erst dann aus dem Speicher
gelesen:

```dart
final result = await plugin.ensureLoggedIn(
  expectedTerminalId: '12345678',
  credentials: () => speicher.lesen(), // GptomCredentials? – null = keine vorhanden
);

switch (result.outcome) {
  case GptomLoginOutcome.alreadyLoggedIn:
  case GptomLoginOutcome.loggedIn:
    break; // Kasse kann starten
  case GptomLoginOutcome.otherTerminal:
    // angemeldet mit anderer TID, es wird nicht umgeschaltet
    break;
  case GptomLoginOutcome.offline:
    // ohne Netz angemeldet (zwischengespeicherter Stand), kein Login-Versuch
    break;
  default:
    if (result.needsCode) {
      // Code abfragen, dann login(authCode: ...) bzw. changePassword(code: ...)
    }
}
```

Der `credentials`-Rückruf muss **immer** zu Ende kommen (auch bei Fehlern);
solange er läuft, antworten andere Konto-Operationen mit `busy`. Auf iOS
öffnet die Statusabfrage kurz GP tom und ein Login ein zweites Mal
(App-Wechsel); `timeout` gilt je Schritt. Ein `timeout` von 0 oder weniger
zählt bei allen Konto-Operationen wie keine Angabe (Standardfrist).

Auf iOS meldet GP tom einen abgemeldeten Zustand teils als Fehler
(`status=ERROR&error=userNotLoggedIn`). Das zählt als abgemeldet, der
Morgen-Check meldet dann an. `networkError` ergibt `offline`, jeder andere
Fehler `failed`.

### Codes: TID-Freigabe und Passwortwechsel

- **TID-Freigabe (nur Android):** Ist die TID noch anderswo belegt, ergibt
  `login()` `tidReleaseRequired` und GP tom schickt einen Code per Mail.
  Die Kasse fragt ihn ab und ruft `login(credentials, authCode: code)` erneut
  auf. Auf iOS gibt es das nicht: `tidOccupied` ist ein Endzustand (manuell
  freigeben), `authCode` ergibt dort `invalidArgument`. Ein leerer oder nur
  aus Leerzeichen bestehender `authCode` zählt auf beiden Plattformen wie
  keiner.
- **Passwortwechsel (Android und iOS):** zweistufig. Schritt 1
  (`changePassword(...)` ohne `code`) ergibt `passwordPendingConfirmation`,
  GP tom schickt einen Code per Mail. Schritt 2 mit `code: ...` ergibt
  `passwordChanged`. Verlangt GP tom beim ersten Login einen Wechsel
  (`passwordChangeRequired`), läuft derselbe Weg.

`GptomLoginResult.needsCode` ist bei `tidReleaseRequired`,
`passwordPendingConfirmation` und `invalidCode` wahr.

Android: Die Login-Ereignisse von GP tom tragen keine Vorgangskennung. Trifft
ein Ereignis erst nach einem Timeout ein, kann es die nächste Operation
derselben Art fälschlich beenden.

## Sicherheit

### Signaturprüfung (Android)

Das Plugin spricht nur mit einer GP-tom-App, deren Signatur-Zertifikat
stimmt. Bei falscher Signatur gehen weder Zugangsdaten noch Zahlungen hinaus
(auch nicht `openGptomUI`) – sonst könnte eine gefälschte App Zahlungen als
genehmigt melden, ohne zu kassieren.

Den Fingerprint der installierten App liest `checkGpTomApp()` aus:

```dart
final check = await plugin.checkGpTomApp();
// check.installed, check.trusted, check.source, check.signatureSha256
```

Diesen Fingerprint fest verdrahten (einmal beim App-Start, **vor** dem ersten
GP-tom-Aufruf):

```dart
GptomAidlPlugin.security = const GptomSecurityConfig(
  trustedSignaturesAndroid: ['AB:CD:...'], // SHA-256, Schreibweise egal
);
```

`GptomAidlPlugin.security` gehört an den App-Start. Ein Wechsel zur Laufzeit
mischt das Verhalten (laufende Aufrufe, vergebene Tokens und gemerkte
Fingerprints richten sich noch nach der alten Einstellung).

Ohne Pins gilt „trust on first use“: **`checkGpTomApp()` speichert beim ersten
Aufruf den Fingerprint der gefundenen App** und erzwingt ihn danach. Ist die
erste gefundene App schon gefälscht, wird sie damit vertraut – deshalb Pins
setzen. Ein legitimer Signaturwechsel von GP tom lässt sich mit
`resetTrustedSignatureAndroid()` auffangen; Key-Rotation (neue Schlüssel
neben den alten) sperrt nicht.

Notschalter in `GptomSecurityConfig`:

| Feld | Standard | Wirkung |
|---|---|---|
| `verifySignatureAndroid` | `true` | `false`: nichts wird geprüft (`source` = `unchecked`), z. B. bei GP tom aus einem anderen Store |
| `trustedSignaturesAndroid` | leer | erlaubte SHA-256-Fingerprints |
| `allowDevPackageInRelease` | `false` | Dev-Paket (`.dev`) auch in Release-Builds erlauben; sonst gesperrt (`devPackageBlocked`) |
| `redirectTokenIOS` | `true` | `false`: altes Verhalten ohne Token (`<scheme>://redirect`, Zuordnung nach Referenz) |
| `sendRequestIdIOS` | `true` | `false`: keine `requestID` an GP tom |

Die Notschalter lassen sich an eine Fernkonfiguration hängen, sollte GP tom
etwas ändern, das die Prüfung bricht.

### Redirect-Token und `requestId` (iOS)

Jede Anfrage bekommt ein geheimes Einmal-Token in der Redirect-URL
(`<scheme>://redirect/<token>`). Nur ein Redirect mit passendem Token
beantwortet einen wartenden Aufruf. Ein von außen geöffneter Link wie
`meineapp://redirect?status=COMPLETED` kann damit keine Zahlung mehr als
bezahlt melden.

Bei Zahlungen ist das Token die `requestId`:

- mit `GptomAidlPlugin.neueVorgangsId()` erzeugen,
- **vor** dem Aufruf von `sell`/`voidSell`/`refund` speichern,
- eine je Zahlungsversuch, nie wiederverwenden,
- nur den **gespeicherten** Wert an `pendingRedirect(requestId:)` und
  `transactionDetailIOS(requestId:)` geben – nie einen Wert aus einem
  Redirect oder einem Ergebnis, sonst bestätigt die Kasse eine Fälschung mit
  deren eigenem Token.

`GptomPendingRedirect.uri` darf die App nicht selbst auswerten; Status,
Beträge und Kennungen kommen nur über `asSellResult()`/`asVoidResult()`.

### Unbestätigte Redirects (`-1007`)

Ein Redirect ohne passendes Token (`isVerified == false`) – oder die Kopie
eines schon beantworteten Redirects – ergibt nie Erfolg,
sondern `GptomResultCode.unverified` (`-1007`, `istUnklar`). Die Kasse klärt
den Fall mit `pendingRedirect(requestId:)` oder
`transactionDetailIOS(requestId:)` und bucht nichts allein aufgrund des
Redirects. Das ist eine bewusste Verhaltensänderung gegenüber 0.2.x.

`GptomAidlPluginIOS.gptomRedirectStream` (roher Strom) führt auch gefälschte
Redirects: daraus **nie** Zahlungen verbuchen.

### Weitere iOS-Hinweise

- Das Passwort steht beim Login und Passwortwechsel in der `gptom://`-URL.
  Das ist das Verfahren von GP tom; das Plugin loggt die URL nicht.
- Deep-Link-Router der App (z. B. `go_router`, `uni_links`) dürfen
  `<scheme>://redirect/...` nicht abfangen, sonst erreicht der Redirect das
  Plugin nicht.
- `LSApplicationQueriesSchemes` muss `gptom` enthalten.

## Vor dem Einsatz auf echten Geräten prüfen

Diese Punkte lassen sich nur mit echter GP-tom-App prüfen:

1. **iOS, Token:** Behält GP tom den Pfad der `redirectUrl`
   (`meineapp://redirect/<token>?status=...`)? Wenn nicht: `redirectTokenIOS`
   ausschalten und das Token neu entwerfen. Ein Verkauf mit Betrag 1111 im
   Simulator reicht als Probe.
2. **iOS, Status/Login/Logout/Passwortwechsel:** Format der Redirects
   (`appStatus`-JSON, `error`-Werte) mit der Doku abgleichen.
3. **iOS, `requestID` und `transaction/detail`:** Kennt die installierte
   GP-tom-Version beides? Ohne Unterstützung bleibt nur der bisherige Weg
   (`sendRequestIdIOS = false`).
4. **Android, Fingerprint:** `checkGpTomApp()` mit der echten App aus dem
   Play Store aufrufen und den Fingerprint als Pin eintragen.
5. **Android, Login-Ereignisse:** Reihenfolge der Callbacks beim Login (kommt
   vorher ein `USER_LOGGED_OUT`?), TID-Freigabe mit Mail-Code, Passwortwechsel
   beim ersten Login.
6. **Android, Rückerstattung ohne Bezug** (`refund` ohne
   `originTransactionId`) gegen App >= 1.75.4.
7. **Android, Auto-Reconnect:** Bleibt die Vertrauensprüfung nach einem
   Neustart von GP tom und dem automatischen Neuverbinden aussagekräftig?
8. **Logout/Login im Zielzustand:** Schickt GP tom ein Ereignis für `logout`,
   wenn schon abgemeldet ist, bzw. für `login`, wenn schon angemeldet ist?
   Sonst läuft der Aufruf in den 60-s-Timeout.
9. **Android, veralteter Status nach Bind:** Schickt der Login-Service direkt
   nach dem Bind einen alten Status, der die erste Operation fälschlich
   beendet?
10. **iOS, Rückerstattung:** Aufbau des Belegs (`transactionId` aus `amsID`).

### Info-Service (nur Android)

```dart
await plugin.bindInfoService();
final info = await plugin.getGpTomInfo();
// info.appVersion, info.isLoggedIn, info.tid, info.mid, info.printerAvailable, ...
plugin.gpTomInfoStream.listen((info) { /* Push bei Änderungen */ });
```

`getGpTomInfo()` wirft nach 20 Sekunden ohne Antwort
`PlatformException(code: 'TIMEOUT')` (nativer Wächter). Bequemer ist
`getStatus()`: es bindet selbst und liefert in dem Fall `null`.

## Fehlercodes

`RequestResult.result` bzw. `resultCode` (GP tom Return-Codes):

| Code | Bedeutung |
|---|---|
| 0 | Erfolg |
| -1 | Transaktion fehlgeschlagen |
| -2 | Ungültige Transaktions-ID |
| -3 | Transaktion nicht gefunden (Neustart möglich) |
| -4 | Transaktion abgelehnt |
| -5 | Bereits storniert |
| -6 | Ungültige Parameter |
| -7 | Nicht autorisiert |
| -8 | Operation nicht erlaubt |
| -9 | Benutzereingabe in GP tom erforderlich |

Zusätzliche Plugin-interne Codes (nur clientseitig, kommen nicht von GP tom):

| Code | Bedeutung |
|---|---|
| -1001 | Antwort fehlte oder war nicht parsebar |
| -1002 | GP tom App konnte nicht geöffnet werden (iOS) |
| -1003 | Keine Antwort binnen der Frist (iOS: kein Redirect, Android: Wächter) |
| -1004 | Redirect ohne Receipt und ohne Erfolgs-Status (iOS; `error.errorCode` = `error` von GP tom, falls vorhanden, sonst `NO_RECEIPT`); bei `transactionDetailIOS` jeder Redirect ohne Beleg, auch mit `COMPLETED` (`error.errorCode` = `error` von GP tom, falls vorhanden) |
| -1005 | Beleg im Redirect nicht lesbar (iOS) |
| -1006 | Abbruch durch Kassier oder Kunde (iOS, `TASK_STATUS=CANCELED`) |
| -1007 | Redirect ohne gültiges Token, nicht bestätigt (iOS); klären mit `pendingRedirect(requestId:)` bzw. `transactionDetailIOS` |

Statt der Zahlen die Konstanten aus `GptomResultCode` verwenden; die
Fehlerkennung in `result.error?.errorCode` steht in `GptomErrorCode`
(`TIMEOUT`, `CANNOT_OPEN`, `NO_RECEIPT`, `PARSE_ERROR`, `CANCELLED`,
`DECLINED`, `UNVERIFIED`).

## Testen in der eigenen App (ohne Gerät)

`package:gptom_aidl_plugin/testing.dart` liefert einen Fake, der alle Aufrufe
aufzeichnet und konfigurierbare Antworten liefert:

```dart
import 'package:gptom_aidl_plugin/testing.dart';

final fake = FakeGptomAidlPluginPlatform();
GptomAidlPluginPlatform.instance = fake;

// Szenario: erste Zahlung abgelehnt, zweite erfolgreich
var calls = 0;
fake.onRequest = (params) =>
    RequestResult(result: ++calls == 1 ? -4 : 0);

// ... App-Code ausführen, danach prüfen, was ankam:
expect(fake.requestCalls.first['preferableReceiptType'], 'EMAIL');
expect(fake.requestCalls.first['clientInfo']['contact']['email'], 'kunde@example.com');

// Pushes simulieren:
fake.emitLoginStatus(GpTomLoginEvent(status: GpTomLoginStatus.userLoggedIn));
```

Für die offizielle Abnahme (Zertifizierungs-Szenarien) stellt GP tom einen
Simulator bereit (Download-Bereich der API-Doku).

## Entwicklung

```bash
flutter test                                        # Dart-Tests
cd example/android && ./gradlew :gptom_aidl_plugin:testDebugUnitTest  # Android-Tests
cd example && flutter run                           # Beispiel-App (Test-Harness)
```

Die JSON-Feldnamen richten sich nach den Entity-Klassen der AIDL-Bibliothek
(`android/repo`, per `javap` einsehbar), nicht nach der Website-Doku –
inklusive der dortigen Tippfehler (`trasanctionID`, `transacitonType`,
`emvAppLable`). Die deutsche Doku-Seite übersetzt teilweise API-Werte
(z. B. Beleg-Typen) – solche Werte nie von dort übernehmen.

## Lizenz

Proprietär – alle Rechte vorbehalten, siehe [LICENSE](LICENSE). Die unter
`android/repo` gebündelte GP tom App2App AIDL-Bibliothek ist Eigentum von
Global Payments und unterliegt deren Bedingungen.

## Doku-Links

- [GP tom API-Übersicht](https://www.gptom.com/en/docs/api/uvod/nez-zacnete/)
- [app2app: transactionRequestV2](https://www.gptom.com/en/docs/api/app2app/2-pozadavek-na-platbu-transactionrequestv2/)
- [Return-Codes](https://www.gptom.com/en/docs/api/app2app/result-codes/)
- [Zertifizierung & Testszenarien](https://www.gptom.com/en/docs/api/uvod/certification-test-cases/)
