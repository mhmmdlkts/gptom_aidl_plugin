# Login, Status und Absicherung (Version 0.3.0)

Stand: 30.10.2026 · Zweig `feature/login-status-sicherheit`

## Anlass und Ziel

Global Payments hat GP tom in „Genius mobile pay“ umbenannt. In der Nacht vom
26. auf den 27.10.2026 wurden nach verdächtigen Aktivitäten alle Benutzer
abgemeldet, und die Kassen standen, bis jemand GP tom von Hand neu anmeldete.
Global Payments empfiehlt deshalb, die Login/Logout-API (Android: App 1.75.2,
AIDL 1.28) und die Statusabfrage (Android: App 1.65.0, AIDL 1.20) einzubauen.

**Ziel:** Die Kasse speichert die GP-tom-Zugangsdaten selbst und gibt sie an
das Plugin. Das Plugin prüft beim Start (z. B. jeden Morgen) den Status, meldet
GP tom bei Bedarf selbst an und führt durch die Sonderfälle (TID-Freigabe,
Passwortwechsel beim ersten Login). Das gilt auf Android und iOS. Dazu kommen
alle neuen GP-tom-Funktionen, die das Plugin abbilden kann, und das Plugin
wird gegen gefälschte Apps und gefälschte Redirects abgesichert.

Die Kasse probiert das zuerst aus. Was nur auf echten Geräten geprüft werden
kann, steht unter „Testplan“.

## Was sich bei GP tom geändert hat (Recherche 30.10.2026)

- **AIDL-Lib bleibt 1.29.0.** Die Download-Seite wurde am 21.10.2026
  aktualisiert (Umbenennung). Paketnamen bleiben `com.globalpayments.atom` und
  `com.globalpayments.atom.dev`. Ein Lib-Update ist nicht nötig.
- **Android, Login-Service** (`com.globalpayments.atom.BIND_TO_LOGIN_SERVICE`):
  `login(json LoginEntity)`, `logout()`, `changePassword(json ChangePasswordEntity)`.
  Das Ergebnis kommt asynchron über `IGPTomLoginChangedCallback.onLoginStatusChanged(status, message)`.
  Im Plugin gibt es das schon, aber nur „abschicken und im Stream lauschen“.
- **Android, Info-Service** (`BIND_TO_INFO_SERVICE`): `getGPTomInfo()` liefert
  `App2AppInfoResponse` mit `logInStatus` = `LOGGED_IN` | `LOGGED_OUT` |
  `UNVERIFIED_LOGGED_IN` (ohne Internet, zwischengespeicherter Stand, seit
  AIDL 1.29). GP tom fragt dabei erst das Backend ab. Der Aufruf ist
  synchron und kann dauern.
- **Android, REFUND (3)** ab App 1.75.4 / AIDL 1.28 („Return/unreferenced
  refund“), `PaymentMethod` (CARD, CASH, ACCOUNT_PAYMENT, PAYMENT_GATEWAY,
  BLIK_PAYMENT, GO_CRYPTO), `originReferenceNum` im Request.
- **iOS (URL-Scheme `gptom://`)**, neu in der Doku und im offiziellen SDK
  `github.com/GP-tom/tom-ios-sdk`:
  - `gptom://login?username&password&tid&redirectUrl` (seit App 1.15)
  - `gptom://change-password?username&password&newPassword&tid[&code]&redirectUrl`
    (zweistufig: ohne `code` schickt GP tom einen Code per Mail, mit `code` wird
    das Passwort gesetzt)
  - `gptom://logout?redirectUrl`
  - `gptom://status?redirectUrl` (seit App 1.7.0), Antwort `status` +
    `appStatus` (JSON: `appVersion`, `userInfo{clientId, email, businessId,
    vatId, tid, mid, tipEnabled, printerAvailable, manualTransactionRestricted,
    merchantLocation{city, county, house, location, street, zip}}`).
    `userInfo` fehlt = abgemeldet.
  - `gptom://transaction/refund?amount&…` (Rückerstattung ohne Bezug auf eine
    Zahlung, Antwort wie beim Verkauf)
  - `gptom://transaction/detail?amsID|requestID&clientID&redirectUrl`
    (SDK-Stand 22.10.2026): liefert den Beleg einer Zahlung zurück. Mit
    `requestID` aus dem Verkauf lässt sich eine Zahlung mit unklarem Ausgang
    auf iOS nachträglich klären.
  - `requestID` als optionaler Parameter bei `transaction/create`
    (lokal auf dem Gerät gültige eigene Kennung).
  - Antwort-Parameter: `status` = `COMPLETED` | `ERROR` | `CANCELLED`, `error`
    = u. a. `invalidCredentials`, `tidNotAssignedToThisUser`,
    `tidAlreadyOccupied`, `anotherTidUsedOnThisDevice`,
    `passwordChangeRequired`, `passwordPendingConfirmation`, `invalidCode`,
    `userNotLoggedIn`, `invalidUserName`, `terminalSetupFailed`, `failed`,
    `networkError`.
  - Auf iOS gibt es **keine** TID-Freigabe per Code (`tidAlreadyOccupied` ist
    dort ein Endzustand) und **keine** Push-Meldung bei Statusänderungen.
  - Beträge im iOS-Beleg kommen als Dezimal-Strings. Das SDK hat in der Woche
    vom 23.10. zwischen Punkt- und Komma-Parsing hin- und hergewechselt. Beide
    Schreibweisen müssen gelesen werden.

## Ziele

1. **Status prüfen, plattformübergreifend:** `getStatus()` liefert ein
   `GpTomInfo` mit eindeutigem Anmeldezustand (`loggedIn`, `loggedOut`,
   `unverifiedLoggedIn`, `unknown`).
2. **Login, Logout, Passwortwechsel zum Abwarten:** `login()`, `logout()`,
   `changePassword()` liefern ein `GptomLoginResult` mit klarem Ausgang statt
   „abgeschickt, Ergebnis irgendwann im Stream“. Das gilt auf Android und iOS.
3. **Morgen-Check:** `ensureLoggedIn()` prüft den Status und meldet mit den
   Zugangsdaten der Kasse an, wenn GP tom abgemeldet ist. Bei TID-Freigabe
   oder Passwortwechsel meldet es den Fall, damit die Kasse den Code abfragen
   kann.
4. **Absicherung Android:** Das Plugin spricht nur mit einer GP-tom-App, deren
   Signatur-Zertifikat stimmt (Fingerprint aus der Konfiguration, sonst
   „trust on first use“).
5. **Absicherung iOS:** Jede Anfrage bekommt ein geheimes Einmal-Token in der
   Redirect-URL. Nur Redirects mit passendem Token beantworten einen wartenden
   Aufruf. Ein von außen geöffneter Link `kasse://redirect?status=COMPLETED`
   kann damit keine Zahlung mehr als bezahlt melden.
6. **Neue Funktionen:** iOS-Rückerstattung, iOS-Belegabfrage
   (`transactionDetailIOS`), `requestId` beim iOS-Verkauf, `referenz`
   (`originReferenceNum`) auch auf Android, `paymentMethod` auf Android,
   Rückerstattung ohne Bezug (`originTransactionId` optional).
7. **Robustheit:** iOS-Beträge ohne Kommazahlen-Rechnung und mit Punkt oder
   Komma lesen. GP-tom-Aufrufe auf Android nicht mehr auf dem Main-Thread.
   `isDev` getrennt je Verbindung. Dev-Paket in Release-Builds sperren.

## Nicht-Ziele

- Das Plugin **speichert keine Zugangsdaten**. Die Kasse hält sie, z. B. mit
  `flutter_secure_storage` (Keychain/Keystore), und reicht sie nur für den
  Login-Aufruf herein.
- Keine Fiskalisierung/EET (`fiscalize`, nur CZ), kein BLIK (PL), keine
  DCC-/Raten-Daten im Modell, keine Cloud-API, keine TID-Freigabe über die
  Cloud-API.
- Kein nativer iOS-Code. iOS bleibt reines Dart (`url_launcher`, `app_links`).
- Keine Brüche der bestehenden API. Alte Methoden bleiben, wo sie ersetzt
  werden, sind sie `@Deprecated` markiert.
- Keine neue AIDL-Lib.

## Anti-Ziele (wäre ein Fehlschlag, auch wenn es „funktioniert“)

- Passwort, Freigabe-Code oder Mail-Code erscheinen in einem Log, einer
  Exception-Message, einem `toString()` oder einem Test-Snapshot.
- Ein Redirect ohne gültiges Token führt automatisch zu „bezahlt“.
- Zugangsdaten gehen an eine Android-App, deren Signatur nicht geprüft wurde.
- Eine Änderung legt iOS-Zahlungen im Betrieb still, ohne dass man sie per
  Schalter zurücknehmen kann (siehe Token, Testplan Punkt 1).
- Der Main-Thread hängt, weil GP tom langsam antwortet.

## Rahmenbedingungen

- Projektkonventionen: Beträge in Cent (`int`), Kommentare/Doku/
  Changelog auf Deutsch, JSON-Feldnamen gemäß AIDL-Lib (Ground Truth per
  `javap`), keine Transaktions-/Belegdaten im Log.
- minSdk 26. Die Signaturprüfung braucht einen Weg für API 26/27
  (`GET_SIGNATURES`) und für ab 28 (`GET_SIGNING_CERTIFICATES` bzw.
  `hasSigningCertificate(…, CERT_INPUT_SHA256)`, beachtet Key-Rotation).
- Version 0.3.0, `CHANGELOG.md` und README pflegen.
- Testdaten nur erfunden (Ersatznamen wie in den anderen Repos, z. B.
  `livia@melisse-nails.example`, TID `12345678`).

## Entwurf

### 1. Neue Typen

```dart
/// Zugangsdaten, die die Kasse hereinreicht. toString() verrät kein Passwort.
class GptomCredentials {
  final String username;   // E-Mail
  final String password;
  final String terminalId; // TID
}

enum GptomLoginState { loggedIn, loggedOut, unverifiedLoggedIn, unknown }

enum GptomLoginOutcome {
  loggedIn,                 // USER_LOGGED_IN, TID_ASSIGNED_AND_LOGGED_IN, iOS COMPLETED
  alreadyLoggedIn,          // ensureLoggedIn: war schon angemeldet (passende TID)
  loggedOut,                // USER_LOGGED_OUT, iOS logout COMPLETED
  tidReleaseRequired,       // Android TID_RELEASE_REQUEST: Code kommt per Mail, login(authCode:) erneut
  tidOccupied,              // iOS tidAlreadyOccupied: kein API-Weg, manuell freigeben
  passwordChangeRequired,   // PASSWORD_CHANGE_REQUIRED / passwordChangeRequired
  passwordPendingConfirmation, // Mail-Code verschickt, changePassword(code:) erneut
  passwordChanged,
  invalidCredentials,
  invalidCode,              // TID_RELEASE_INVALID_CODE / invalidCode
  tidNotAssignedToUser,
  anotherTidOnDevice,
  tidNotFound,
  tidNotActive,
  tidNotSelected,
  invalidArgument,          // INVALID_ARGUMENT / invalidUserName
  terminalSetupFailed,
  otherTerminal,            // ensureLoggedIn: angemeldet, aber mit anderer TID
  offline,                  // UNVERIFIED_LOGGED_IN (kein Login-Versuch) / iOS networkError
  noCredentials,            // ensureLoggedIn: Kasse hat keine Zugangsdaten geliefert
  notInstalled,
  untrustedApp,             // Android: Signatur passt nicht
  notSupported,             // Login-/Info-Service fehlt (GP tom zu alt)
  cannotOpen,               // iOS: gptom:// ließ sich nicht öffnen
  cancelled,                // iOS CANCELLED
  timeout,
  busy,                     // es läuft schon eine Login-Operation
  failed,                   // LOGIN_FAILED, LOGOUT_FAILED, PASSWORD_CHANGE_FAILED, failed, userNotLoggedIn (beim Status: abgemeldet)
  unknown,                  // unbekannter Status, roher Wert bleibt erhalten
}

class GptomLoginResult {
  final GptomLoginOutcome outcome;
  final String? rawStatus;  // Android-Status bzw. iOS `status`
  final String? rawError;   // iOS `error`
  final String? message;    // Android-`message`, nie mit Zugangsdaten
  final GpTomInfo? info;    // bei ensureLoggedIn der zuletzt gelesene Status
  bool get isLoggedIn;      // loggedIn | alreadyLoggedIn
  bool get needsCode;       // tidReleaseRequired | passwordPendingConfirmation | invalidCode
}

class GptomAppCheck {       // Ergebnis der Prüfung der GP-tom-App
  final bool installed;
  final bool trusted;
  final GptomTrustSource source;
  // pinned | firstUse | mismatch | unchecked (Prüfung abgeschaltet)
  // | notInstalled | notApplicable (iOS)
  final List<String> signatureSha256; // Großbuchstaben, mit Doppelpunkten
  final String? versionName;
  final int? versionCode;
}

class GptomSecurityConfig {
  /// Signaturprüfung auf Android. false = Notschalter: nichts wird geprüft
  /// (source `unchecked`), z. B. wenn GP tom aus einem anderen Store kommt.
  final bool verifySignatureAndroid;          // Standard true
  /// SHA-256-Fingerprints, denen vertraut wird. Leer = „trust on first use“:
  /// die erstgesehene Signatur wird gemerkt und danach erzwungen.
  final List<String> trustedSignaturesAndroid;
  /// Dev-Paket (Simulator) auch in Release-Builds erlauben.
  final bool allowDevPackageInRelease;        // Standard false
  /// Einmal-Token in der iOS-Redirect-URL (Notschalter, siehe Testplan 1).
  final bool redirectTokenIOS;                // Standard true
  /// `requestID` an GP tom mitschicken (iOS; Notschalter, siehe Testplan 3).
  final bool sendRequestIdIOS;                // Standard true
}
```

Die Konfiguration ist zur Laufzeit änderbar. Die Kasse kann die Notschalter
also an eine Fernkonfiguration hängen und braucht dafür kein neues Release.

`GpTomInfo` bekommt `loginState` (`GptomLoginState`) und
`merchantLocationText` (Android-Feld `merchantLocation` als String).
`merchantLocationEntity` bleibt. `GpTomInfo.fromIosAppStatus(Map)` liest die
iOS-Struktur (`userInfo.vatId` → `vat`, `userInfo.merchantLocation` →
`merchantLocationEntity`). Gelesen wird nachsichtig: Texte über `toString()`
(eine TID als Zahl wird `'12345678'`), Wahrheitswerte als `true`/`false` oder
`'true'`/`'false'`, sonst `null`; Maps nur, wenn es eine Map ist.

Konfiguration: `GptomAidlPlugin.security = GptomSecurityConfig(...)`
(statisch, einmal beim App-Start). Der Dart-Teil gibt die Fingerprints bei
jedem Bind und jeder Prüfung mit. Die native Seite hält dafür keinen eigenen
Konfigurationszustand.

### 2. Öffentliche API (Fassade `GptomAidlPlugin`)

| Methode | Android | iOS |
|---|---|---|
| `Future<GptomAppCheck> checkGpTomApp({isDevAndroid})` | Signatur und Version | `installed` = `canLaunchUrl(gptom://)`, `trusted` = true, `source` = `notApplicable` (iOS kann das nicht prüfen) |
| `Future<GpTomInfo?> getStatus({isDevAndroid, timeout})` | bindet Info-Service bei Bedarf, `getGPTomInfo` im Hintergrund-Thread | `gptom://status` und Redirect (Standard-Timeout 30 s) |
| `Future<GptomLoginResult> login(GptomCredentials, {authCode, isDevAndroid, timeout})` | bindet Login-Service bei Bedarf, wartet auf passenden Status (Standard 60 s) | `gptom://login`. `authCode` wird auf iOS abgelehnt (`invalidArgument`), weil es dort keine TID-Freigabe gibt |
| `Future<GptomLoginResult> logout({isDevAndroid, timeout})` | `logout()` und Status | `gptom://logout` |
| `Future<GptomLoginResult> changePassword({required username, required currentPassword, required newPassword, required terminalId, String? code, …})` | Schritt 1 = `code == null` → `validationOnly: true`, Schritt 2 → `authCode: code, validationOnly: false`. `username`/`terminalId` werden nicht gebraucht | `gptom://change-password`, `code` nur in Schritt 2 |
| `Future<GptomLoginResult> ensureLoggedIn({required FutureOr<GptomCredentials?> Function() credentials, String? expectedTerminalId, isDevAndroid, timeout})` | siehe 3. | siehe 3. |
| `Future<RequestResult> refund({…, String? originTransactionId, …})` | `originTransactionId` optional (ohne = Rückerstattung ohne Bezug) | `gptom://transaction/refund`, neu |
| `Future<RequestResult> transactionDetailIOS({String? amsId, String? requestId, String? clientId, Duration? timeout})` | wirft `PlatformException` (Android hat `inquireTransactionAndroid`) | `gptom://transaction/detail`, Ergebnis siehe 6. (Parser). Nur per `requestId` bei `sendRequestIdIOS = false`: `ArgumentError` vor dem Öffnen |
| `sell`/`voidSell`/`refund`: neuer Parameter `requestId` (nur iOS) | ignoriert | Vorgangskennung, siehe 6. Die Kasse erzeugt sie mit `GptomAidlPlugin.neueVorgangsId()` und **speichert sie vor dem Aufruf**. Ohne Angabe erzeugt das Plugin eine, nach einem Kaltstart ist sie dann aber verloren. Sie steht immer in `RequestResult.requestId`, auch bei Timeout |
| `sell(referenz:)` | neu: wird als `originReferenceNum` gesendet | wie bisher |
| `sell`/`registerTransactionV2Android`: `paymentMethod` (`GptomPaymentMethod`) | `paymentMethod` im Register- und Request-JSON | ignoriert |
| `resetTrustedSignatureAndroid({isDevAndroid})` | löscht den gemerkten Erst-Fingerprint | keine Wirkung |
| `pendingRedirect({originReferenceNum, requestId})` | keine Wirkung | neu `requestId` (Kaltstart-Bestätigung), `GptomPendingRedirect.isVerified`, `.requestId`. Ohne Angabe bzw. per Referenz zuerst der älteste bestätigte Eintrag, siehe 6. |
| `static String neueVorgangsId()` | – | 32 Hex-Zeichen aus `Random.secure` |

`referenz` wird auf beiden Plattformen geprüft: höchstens 20 Zeichen, nur
ASCII, sonst `ArgumentError` (GP tom: „max. 20 Zeichen, keine Diakritik“).

Bestehende Methoden `loginGpTom`, `logoutGpTom`, `changeGpTomPassword`,
`bindLoginService`, `bindInfoService`, `getGpTomInfo` und die Streams bleiben.
`loginGpTom`/`logoutGpTom`/`changeGpTomPassword` werden `@Deprecated` mit
Verweis auf die neuen Methoden.

### 3. Ablauf `ensureLoggedIn`

1. `checkGpTomApp` → nicht installiert: `notInstalled`. Android und nicht
   vertrauenswürdig: `untrustedApp`.
2. `getStatus` → kein Ergebnis: `notSupported` bzw. `timeout`.
3. `loggedIn` → passt `expectedTerminalId` (oder ist null): `alreadyLoggedIn`.
   Sonst `otherTerminal`, **ohne** Umschalten (das entscheidet die Kasse).
4. `unverifiedLoggedIn` → `offline`, kein Login-Versuch (ohne Netz sinnlos).
5. `loggedOut`/`unknown` → `credentials()` aufrufen. `null`: `noCredentials`.
   Sonst `login(creds)` und dessen Ergebnis zurückgeben.
6. `info` im Ergebnis ist der Stand aus Schritt 2.

`credentials` wird erst in Schritt 5 aufgerufen, damit das Passwort nur bei
Bedarf aus dem sicheren Speicher kommt. Auf iOS öffnet Schritt 2 kurz GP tom
(App-Wechsel) und Schritt 5 ein zweites Mal. Das steht in der Doku.

### 4. Login-Ablauf Android (Abwarten im Dart-Teil)

- Eine Login-Operation zur Zeit (Sperre im Dart-Teil). Ein zweiter Aufruf,
  solange einer läuft: `busy`.
- **Vor** dem nativen Aufruf auf `loginStatusStream` horchen, dann aufrufen,
  dann auf das erste Ereignis warten, das zur Operation passt:
  - login: alles außer `USER_LOGGED_OUT`, `LOGOUT_FAILED`,
    `PASSWORD_PENDING_CONFIRMATION`, `PASSWORD_CHANGED`,
    `PASSWORD_CHANGE_FAILED`. Unbekannte Werte beenden mit `unknown`.
  - logout: `USER_LOGGED_OUT`, `LOGOUT_FAILED`.
  - changePassword: `PASSWORD_PENDING_CONFIRMATION`, `PASSWORD_CHANGED`,
    `PASSWORD_CHANGE_FAILED`, `INVALID_ARGUMENT`, `INVALID_CREDENTIALS`.
- Timeout: `timeout`. Ein Bind-Fehler wird zu `notSupported` (Service fehlt),
  eine falsche Signatur zu `untrustedApp`.

### 5. Android nativ (`GptomAidlPlugin.java`)

- **Signaturprüfung** `verifyTarget(pkg, trusted[], tofu)` vor jedem
  `bindService` (Payment, Login, Info) und vor dem `startActivity` für
  `openGptomUI`:
  - API ≥ 28: Signer-Fingerprints aus `SigningInfo`. Pin-Treffer per
    `hasSigningCertificate(pkg, sha256, CERT_INPUT_SHA256)`, das deckt
    Key-Rotation ab.
  - API 26/27: `GET_SIGNATURES`, SHA-256 je Signatur.
  - Fingerprint-Format: SHA-256, Großbuchstaben mit `:`. Eingaben ohne `:`
    oder in Kleinbuchstaben werden normalisiert.
  - Pins vorhanden: Treffer → `pinned`, sonst `mismatch` (Bind liefert
    `false`, kein Kontakt zur App).
  - Keine Pins, `tofu = true`: erster Fingerprint je Paket in
    `SharedPreferences` (`gptom_aidl_plugin_trust`). Später muss er passen,
    sonst `mismatch`.
  - Neue Methoden im Channel: `checkGpTomApp`, `resetTrustedSignature`.
- **Getrenntes `isDev`** je Verbindung (`paymentIsDev`, `loginIsDev`,
  `infoIsDev`). `openGptomUI` nutzt das Paket der Payment-Verbindung.
- **Hintergrund-Threads:** Alle Binder-Aufrufe sind synchron (geprüft per
  `javap`, kein `oneway`). Deshalb laufen sie nicht auf dem Main-Thread,
  sondern auf zwei getrennten Executoren mit je einem Thread: einer für den
  Payment-Service, einer für Login- und Info-Service. Ein langsames
  `getGPTomInfo` beim Morgen-Check (offline) hält so keine Zahlung auf.
  Ergebnisse gehen über `SingleResult` auf den Main-Thread. Wächter:
  `getGpTomInfo` 20 s, `registerTransactionV2` 30 s (beide über das
  Steuerfeld `timeoutMs`), `requestTransactionV2` wie bisher 240 s.
- **Was eine falsche Signatur sperrt:** alles, also auch Zahlungen. Eine
  gefälschte App könnte sonst Zahlungen als genehmigt melden, ohne zu
  kassieren. Auswege: Notschalter `verifySignatureAndroid = false`,
  `resetTrustedSignatureAndroid()` und ein weiterer Fingerprint in
  `trustedSignaturesAndroid`. Key-Rotation von Global Payments ist über
  `hasSigningCertificate` abgedeckt und sperrt nicht.
- Keine Zugangsdaten in `Log`, keine `e.getMessage()` aus dem Login-Pfad in
  Fehlermeldungen. Dort nur feste Texte.
- Release-Sperre für das Dev-Paket sitzt im Dart-Teil (`kReleaseMode`). Die
  native Seite bekommt nur das Ergebnis.

### 6. iOS (Dart)

- **Vorgangskennung = Token:** Für Verkauf, Storno und Rückerstattung ist das
  Token die `requestId` (32 Hex-Zeichen aus `Random.secure`, erzeugt von
  `neueVorgangsId()`). Sie geht als Pfad in die `redirectUrl`
  (`<scheme>://redirect/<requestId>`) und, solange `sendRequestIdIOS` an ist,
  als `requestID` an GP tom. Da die Kasse sie vor dem Aufruf speichert, kann
  sie einen Redirect auch nach einem Kaltstart bestätigen, ohne dass das
  Plugin etwas speichern muss. Ein Angreifer kennt die Kennung nicht.
  Login, Logout, Passwortwechsel, Status, Kassenschnitt und Belegabfrage
  bekommen ein eigenes zufälliges Token. Der Wartende nimmt nur einen
  Redirect mit genau diesem Token an.
  - Hex enthält keine der Zeichenfolgen, auf die GP tom beim Erkennen des
    Anfrage-Typs per `contains` prüft (`login`, `logout`, `status`,
    `transaction/…`, `batch/…`). Deshalb steht im Pfad **kein**
    Operationsname.
  - **Token-Arten:** Das Plugin merkt sich jedes ausgegebene Token mit seiner
    Art (höchstens 50, älteste fallen heraus): `zahlung` (Verkauf, Storno,
    Rückerstattung) oder `sonstige` (Login, Logout, Passwortwechsel,
    Status, Kassenschnitt, Belegabfrage).
  - Redirects mit unbekanntem oder fehlendem Token beantworten keinen
    Wartenden. Sie landen im Puffer als `GptomPendingRedirect` mit
    `isVerified = false`. Ein später Redirect (Wartender hat schon
    aufgegeben) mit einem `zahlung`-Token landet mit `isVerified = true`,
    höchstens einmal je Token (weitere Kopien unbestätigt). Ein später
    Redirect mit einem `sonstige`-Token kommt **gar nicht** in den Puffer,
    nur in den Rohstrom: Ein verspäteter Status- oder Login-Redirect mit
    `status=COMPLETED` darf nie als Zahlung lesbar werden.
  - **Verbrauchte Tokens:** Nimmt ein Wartender den Redirect an oder holt
    die Kasse einen bestätigten Eintrag ab, ist das Token verbraucht
    (gemerkt, höchstens 50). Eine spätere Kopie desselben Redirects ist
    unbestätigt (-1007), auch über `pendingRedirect(requestId:)`.
  - Nach einem Kaltstart kennt das Plugin keine Tokens mehr. Neue Abholung
    `pendingRedirect(requestId: gespeicherteId)`: Ein Redirect, dessen Token
    gleich `requestId` ist, gilt als bestätigt, solange das Token in diesem
    Prozess nicht verbraucht ist. Die bisherige Abholung über
    `originReferenceNum` bleibt, bestätigt aber nur Redirects mit einem
    offenen `zahlung`-Token aus diesem Prozess.
  - **Abholung und Puffergrenze:** `pendingRedirect()` ohne Angabe und mit
    `originReferenceNum` liefert zuerst den ältesten bestätigten Treffer,
    erst wenn es keinen gibt den ältesten unbestätigten. Ist der Puffer
    voll (10), fällt zuerst der älteste unbestätigte Eintrag heraus, erst
    dann der älteste bestätigte. Eine Flut gefälschter Links verdrängt oder
    verdeckt so keine echte Zahlung.
  - **`asSellResult()`/`asVoidResult()`/`asRefundResult()` auf einem
    unbestätigten Redirect liefern nie Erfolg**, sondern den neuen Code
    `GptomResultCode.unverified` (-1007, `istUnklar` = true,
    `error.errorCode = 'UNVERIFIED'`). Damit kann ein gefälschter Link mit
    einer erratbaren Rechnungsnummer nichts mehr als bezahlt verbuchen. Die
    Kasse klärt den Fall mit `pendingRedirect(requestId:)` oder
    `transactionDetailIOS(requestId:)`. Das ist eine bewusste
    Verhaltensänderung und steht im CHANGELOG.
  - Unbestätigte Einträge und ihre Ergebnisse geben **keine** Kennung heraus
    (`GptomPendingRedirect.requestId` und `RequestResult.requestId` sind
    `null`): Das Token im Pfad hat der Absender gewählt. Die Kennung für
    `pendingRedirect(requestId:)` kommt immer aus dem Speicher der Kasse.
  - `GptomSecurityConfig.redirectTokenIOS = false` stellt das alte Verhalten
    her (`<scheme>://redirect`, Annahme nach Referenz, jeder Redirect gilt
    als bestätigt). Damit kehrt auch das alte Risiko zurück: Ein später
    Redirect von Status, Login oder Kassenschnitt landet bestätigt im Puffer
    und wäre als Zahlung lesbar. Das ist hinnehmbar, weil es der
    Notschalter ist (Testplan Punkt 1), nicht der Betrieb.
- **Neue URL-Bauer** (`@visibleForTesting`): `buildLoginUri`,
  `buildLogoutUri`, `buildChangePasswordUri`, `buildStatusUri`,
  `buildRefundUri`, `buildTransactionDetailUri`. Für Login und
  Passwortwechsel wird die Query **selbst** mit `Uri.encodeComponent`
  gebaut (Leerzeichen → `%20`, nicht `+`). GP tom liest Query-Werte ohne
  Formular-Decoding, ein `+` bliebe ein `+` und das Passwort wäre falsch.
- **Parser:** `loginResultFromRedirect(uri, operation)` bildet
  `status`/`error` auf `GptomLoginOutcome` ab. Bei change-password heißt
  `COMPLETED` ohne `code` `passwordPendingConfirmation`, mit `code`
  `passwordChanged`. `infoFromStatusRedirect(uri)` liest `appStatus`.
  Die Statusabfrage wertet `status=ERROR` aus: `error=userNotLoggedIn` →
  `GpTomInfo(loginState: loggedOut)` ohne Fehler (der Morgen-Check meldet
  dann an), `networkError` → `offline`, jeder andere Fehler → `failed`.
  `CANCELLED` → `cancelled`, `COMPLETED` ohne lesbaren `appStatus` →
  `unknown`. Bei Login/Logout/Passwortwechsel bleibt `userNotLoggedIn`
  `failed`.
  Refund nutzt den bestehenden Beleg-Parser (`transactionType` = `refund`).
  Detail (`requestResultFromDetailRedirect`) verlangt einen Beleg: Ohne
  `receipt` ist das Ergebnis `noReceipt` (-1004), auch bei
  `status=COMPLETED` – die Abfrage ist gelungen, über die Zahlung sagt das
  nichts. `error.errorCode` ist dann der `error`-Wert von GP tom (sonst
  `NO_RECEIPT`), `responseMessage` der `status`. Mit Beleg wird er wie beim
  Verkauf gelesen, aber `transactionType` bleibt `null`: Das gleichnamige
  Feld im Beleg ist die Zahlungsart, nicht Verkauf oder Storno.
- **Beträge:** `_centsFromReceipt` und `Batch._asCents` lesen Dezimal-Strings
  ohne `double`, Regeln in dieser Reihenfolge:
  1. Leerzeichen entfernen.
  2. Kommen `.` und `,` beide vor, ist das letzte das Dezimalzeichen, die
     anderen sind Tausender-Trennzeichen. Sie müssen gültige
     Tausender-Gruppen bilden (siehe 3.), sonst `null` (`1.2.3,4`,
     `1,2,3.4`).
  3. Kommt nur eine Art vor, ist sie ein Tausender-Trennzeichen, wenn alle
     Gruppen danach genau drei Ziffern haben und die erste Gruppe ein bis
     drei Ziffern ohne führende Null (`1.234`, `1,234`, `1.234.567`). Drei
     Nachkommastellen gibt es bei EUR nicht. `0,995` ist deshalb kein
     Tausender (erste Gruppe `0`), sondern ein Dezimalwert. Kommt die Art
     mehrfach vor, ohne gültige Gruppen zu bilden (`1.234.56`), ist der
     Betrag unlesbar (`null`).
  4. Sonst ist es das Dezimalzeichen. Nachkommastellen auf zwei auffüllen,
     mehr als zwei kaufmännisch runden (`0,995` → 100 Cent).
  5. Zahlen (`num`) aus JSON: `toString()`, `.` ist immer das
     Dezimalzeichen, Regel 3 gilt hier nicht.
  6. Unlesbar: `null` wie bisher.

### 7. Beispiel-App und Doku

- Beispiel-App: Bereich „GP tom Anmeldung“ mit Status, Login (Eingabefelder,
  keine Vorbelegung echter Daten), Code-Eingabe für TID-Freigabe bzw.
  Passwortwechsel, Logout, Anzeige von `checkGpTomApp` inkl. Fingerprint.
- README: Morgen-Check-Beispiel, sichere Ablage der Zugangsdaten in der Kasse,
  Signatur-Pinning (wie man den Fingerprint mit `checkGpTomApp` ausliest),
  iOS-Hinweise (App-Wechsel bei Status/Login, Passwort steht in der URL an
  `gptom://`, Token und Schalter, `LSApplicationQueriesSchemes`: `gptom`),
  Deep-Linking-Router der App dürfen `<scheme>://redirect/...` nicht abfangen.
- CHANGELOG 0.3.0, `pubspec.yaml` 0.3.0.

### 8. Tests

- Dart: Outcome-Abbildung (alle Android-Status, alle iOS-Status/-Fehler),
  Login-Abwarten mit gestreamten Ereignissen (passend, unpassend, Timeout,
  `busy`), `ensureLoggedIn`-Entscheidungstabelle über
  `FakeGptomAidlPluginPlatform`, URL-Bauer (Sonderzeichen im Passwort:
  Leerzeichen, `+`, `&`, `%`, `#`, Umlaute), Token-Annahme/-Ablehnung,
  Puffer mit `isVerified`, Schalter `redirectTokenIOS = false`,
  Betrags-Parsing (`"4.35"`, `"4,35"`, `"1 234,50"`, `"1.234,50"`, `"10"`,
  `"1.234"`, `"1,234"`, `"1.234.567"`, `"4.355"` als String = Tausender,
  `"0,995"` = 100, `"1.234.56"`/`"1.2.3,4"` = `null`, `4.35`, `95.5`,
  `"abc"`), unbestätigte Redirects liefern nie Erfolg, späte Redirects von
  Status/Login/Kassenschnitt nicht im Puffer, Kopien verbrauchter Tokens
  unbestätigt, Abholung und Puffergrenze „bestätigt zuerst“,
  Kaltstart-Bestätigung über `requestId`, Belegabfrage ohne Beleg = -1004,
  Statusfehler (`userNotLoggedIn`, `networkError`), Redaction (`toString`
  von Credentials/Results enthält kein Passwort).
- `FakeGptomAidlPluginPlatform` bekommt die neuen Methoden, steuerbare
  Login-Ereignisse und einen `appCheck`.
- Android (Robolectric): Signaturprüfung (Pin passt/passt nicht,
  Erstvertrauen speichern/abweisen, Reset), getrenntes `isDev`,
  `getGpTomInfo` nicht auf dem Main-Thread und mit Wächter, Login-Aufrufe
  ohne Bindung → `NOT_BOUND`.

## Testplan auf echten Geräten (vor dem Einsatz)

1. **iOS, Token:** Behält GP tom den Pfad der `redirectUrl`
   (`kasse://redirect/<token>?status=…`)? Wenn nicht: Schalter aus, Token
   neu entwerfen. Ein Verkauf im Simulator-Betrag 1111 reicht als Probe.
2. **iOS, Status/Login/Logout/Passwortwechsel:** Format der Redirects
   (`appStatus`-JSON, `error`-Werte) mit der Doku abgleichen.
3. **iOS, `requestID` und `transaction/detail`:** Kennt die installierte
   GP-tom-Version das schon? Ohne Unterstützung bleibt nur der bisherige Weg.
4. **Android, Fingerprint:** `checkGpTomApp` auf einem Gerät mit der echten
   GP-tom-App aus dem Play Store aufrufen. Den Fingerprint danach als
   eingebauten Standard ins Plugin übernehmen (eigener kleiner Schritt), damit
   die Prüfung ab Werk streng ist.
5. **Android, Login-Ereignisse:** Reihenfolge der Callbacks beim Login
   (kommt vorher ein `USER_LOGGED_OUT`?), TID-Freigabe mit Mail-Code,
   Passwortwechsel beim ersten Login.
6. **Android, Rückerstattung ohne Bezug** (`REFUND` ohne
   `originTransactionID`) gegen App ≥ 1.75.4.

## Entscheidungen beim Entwurf (zum Gegenlesen)

1. Unbestätigte iOS-Redirects ergeben nie „bezahlt“, sondern
   `unverified` (-1007). Die Kasse muss die `requestId` vor jeder
   iOS-Zahlung speichern, wenn sie Kaltstarts sauber auflösen will.
2. Auf Android sperrt eine falsche Signatur auch Zahlungen. Dafür gibt es
   einen Notschalter, ein Reset und eine erweiterbare Pin-Liste.
3. `requestID` wird auf iOS immer mitgeschickt, abschaltbar über
   `sendRequestIdIOS`.
4. Getrennte Threads für Zahlung und Login/Info.
5. `1.234` als String ist ein Tausender-Trennzeichen, `1.234` als JSON-Zahl
   ein Dezimalwert.
6. `ensureLoggedIn` schaltet bei fremder TID nicht selbst um, sondern meldet
   `otherTerminal`.
7. Ohne eingebauten Fingerprint startet Android mit „trust on first use“.
   Der echte Fingerprint kommt nach Testplan Punkt 4 dazu.
8. Nur Zahlungs-Tokens können einen bestätigten Puffereintrag erzeugen,
   und jedes Token bestätigt höchstens einmal. Späte Redirects anderer
   Aufrufe werden verworfen. Im Altmodus (`redirectTokenIOS = false`) gilt
   das nicht – bewusst, er ist nur der Notschalter.
9. Die Belegabfrage zählt nur mit Beleg als Erfolg; `COMPLETED` allein
   ergibt dort -1004.

## Offen für die Umsetzung (Entscheidung beim Bauen)

- Aufteilung von `gptom_aidl_plugin_ios.dart` in mehrere Dateien.
- Genaue Benennung der Steuerfelder im Channel.
- Ob `checkGpTomApp` das Ergebnis kurz zwischenspeichert.
