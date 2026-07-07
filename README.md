# gptom_aidl_plugin

Flutter-Plugin zur Anbindung der [GP tom](https://www.gptom.com) App (Global
Payments SoftPOS) aus der eigenen App heraus – Kartenzahlungen, Storno,
Rückerstattung, Kassenschnitt, Login- und Info-Service.

| Plattform | Anbindung | Umfang |
|---|---|---|
| Android (minSdk 26) | app2app **AIDL** (`com.gptom.app2app:aidl` 1.29.0) | Sale, Void, Refund, Close Batch, Status, Details, Login-/Info-Service |
| iOS | **URL-Scheme** `gptom://` + Redirect | Sale, Void, Close Batch |

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
  tipAmountCents: 100,
  preferableReceiptType: PreferableReceiptType.email,
  clientInfo: {
    'email': 'kunde@example.com',
    'phone': '+436601234567',
  },
);

if (result.result == 0) {
  // Erfolgreich – result.approvedCode, result.cardNumber (maskiert), ...
} else {
  // result.error?.errorMessage liefert eine deutsche Beschreibung
}
```

`clientInfo` nimmt die flachen Keys `email`/`phone` entgegen; das Plugin
wandelt sie in die von GP tom erwartete `contact`-Struktur um.

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

await plugin.refund( // nur Android
  transactionIdAndroid: neueRegistrierteId,
  originTransactionId: original.transactionId!,
  amountCents: 500,
);

final batch = await plugin.closeBatch(transactionIdAndroid: neueRegistrierteId);
// Android: RequestResult, iOS: Batch (inkl. subBatches je Zahlungsart)
```

### Login-Service (nur Android, GP tom >= 1.65)

Das Ergebnis kommt asynchron über den Stream:

```dart
await plugin.bindLoginService();

plugin.loginStatusStream.listen((event) {
  // event.status: userLoggedIn, invalidCredentials, passwordChangeRequired, ...
});

await plugin.loginGpTom(
  username: 'kasse@example.com',
  password: '...',
  terminalId: '11263520',
);
```

### Info-Service (nur Android)

```dart
await plugin.bindInfoService();
final info = await plugin.getGpTomInfo();
// info.appVersion, info.isLoggedIn, info.tid, info.mid, info.printerAvailable, ...
plugin.gpTomInfoStream.listen((info) { /* Push bei Änderungen */ });
```

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
| -1003 | Kein Redirect erhalten / Timeout (iOS) |
| -1004 | Redirect ohne Receipt (iOS) |

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
