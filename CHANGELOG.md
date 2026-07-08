## 0.2.1

* **Fix (iOS, Zahlungsverlust):** Ein erfolgreicher Redirect ohne `receipt`
  wurde bisher pauschal als `-1004` verworfen – eine tatsächlich belastete
  Karte galt damit als abgebrochen und fehlte in der Aufzeichnung. GP tom
  meldet den Abschluss in diesem Fall nur über `query["status"]`
  (`COMPLETED`/`APPROVED`); dieser Status wird jetzt ausgewertet und als
  Erfolg (`result: 0`) gewertet. Ohne Beleg fehlen die Kartendetails
  (amsID/Betrag) – der Abschluss selbst ist verlässlich. Nicht-Erfolgs-Fälle
  bleiben `-1004`, reichen aber den echten `status` als `responseMessage`
  durch, statt ihn zu verwerfen.

## 0.2.0

* **Fix (Beleg-Daten):** `preferableReceiptType` sendet jetzt die Werte, die
  GP tom tatsächlich versteht. Die bisherigen deutschen Werte (`TELEFON`,
  `E-MAIL`, `DRUCKEN`) stammen aus einem Übersetzungs-Artefakt der deutschen
  Doku-Seite und wurden von GP tom stillschweigend verworfen (Gson-Enum
  `ReceiptType`: `PHONE`, `EMAIL`, `QR`, `PRINT`; iOS-URL-Scheme: `sms`,
  `email`, `qr`, `print`). `PreferableReceiptType.key` ist deprecated,
  stattdessen `aidlKey`/`iosKey` – die Plugin-Methoden wählen selbst den
  richtigen Wert.
* **Fix (Beleg-Daten):** `clientInfo` wird für Android in die von GP tom
  erwartete Struktur `{"contact":{"email":…,"phone":…}}` gehoben
  (`ClientInfoEntity` → `UserContactEntity`). Flache Maps (`{email, phone}`)
  wurden bisher stillschweigend verworfen; die flache Form bleibt an der
  Plugin-API weiterhin erlaubt.
* Fix: `RequestResult` liest `emvAppLabel` jetzt in der korrekten
  Schreibweise der V2-Antwort (der Tippfehler `emvAppLable` existiert nur in
  der Inquire-Antwort und wird dort weiterhin – mit Fallback – gelesen).
* Fix: `RequestResult.toMap()` schreibt jetzt dieselben Keys, die
  `fromMap()` liest (`transactionID`, `transactionType`, `emvAppLabel`,
  neu inkl. `amsID`) – Roundtrip war vorher inkonsistent.
* Neu: `package:gptom_aidl_plugin/testing.dart` mit
  `FakeGptomAidlPluginPlatform` – Apps können damit in eigenen Tests prüfen,
  ob Beleg-/Transaktionsdaten korrekt beim Plugin ankommen (zeichnet alle
  Aufrufe auf, Antworten und Status-Pushes konfigurierbar).
* Neu: Wire-Format-Tests (exaktes JSON über den MethodChannel inkl.
  Backend-Tippfehler-Keys), iOS-URL-Scheme-Tests (URI-Aufbau und
  Redirect-/Receipt-/Batch-Parsing) und Beleg-Daten-Tests. Dafür sind die
  iOS-URI-Builder und Redirect-Parser als testbare statische Methoden
  extrahiert (`@visibleForTesting`, Verhalten unverändert).
* **Robustheit:** Alle `fromJson`-Factories (`RegisterResult`,
  `RequestResult`, `StateResult`, `InquireResult`) liefern bei kaputtem oder
  unerwartetem JSON jetzt ein Fehler-Ergebnis (result/resultCode -1001)
  statt zu werfen; `Batch`/`SubBatch` parsen defensiv (fehlende Felder →
  Defaults, numerische Strings toleriert). `RegisterResult` parst jetzt auch
  das `error`-Objekt und bietet `isSuccess`.
* Fix: `RegisterResult.fromJson` hat bei Nicht-Map-JSON ein Objekt
  *geworfen* statt es zurückzugeben.
* Fix: `SubBatch.exists` war praktisch immer `false` (verlangte u. a.
  `voidCount > 0`); jetzt: Transaktionen oder Betrag vorhanden.
* Fix: `InquireResult.transactionType` mappt über `TransactionType.fromId`
  (inkl. Fallback auf die korrekt geschriebene Key-Variante).
* **API:** `sell`/`refund` validieren Beträge (`amountCents > 0`,
  `tipAmountCents >= 0`, sonst `ArgumentError`); `closeBatch` ist als
  `Future<Object?>` typisiert (Android: `RequestResult`, iOS: `Batch`);
  neue optionale `redirectTimeoutIOS`-Parameter (Standard: 60 s Transaktion,
  15 s Kassenschnitt); `Batch.subBatch(key)` als null-sicherer Zugriff.
* Neu: Fake-Szenario-Handler (`onRegister`, `onRequest`, `onStateRequest`,
  `onInquire`) für App-Tests wie "erst abgelehnt, dann erfolgreich" oder
  Status-Verläufe.
* Fix: Der Android-Unit-Test war noch der (fehlschlagende) Flutter-Template-
  Test; ersetzt durch echte Tests mit Robolectric (NOT_BOUND-Pfade,
  App-Erkennung, Entfernen der Steuerfelder aus dem Request-JSON,
  Cent-Beträge bleiben Ganzzahlen).
* README komplett neu (Setup Android/iOS, Ablauf, Beleg-Daten, Fehlercodes,
  Test-Anleitung), Beispiel-App als manueller Test-Harness, CI-Workflow
  (analyze, Dart- und Android-Unit-Tests), Logging via `debugPrint`.

## 0.1.0

* **Breaking:** Alle Geldbeträge in der API sind jetzt `int` in Cent statt
  `double` in Euro – durchgängig ohne Fließkomma-Mathematik:
  * Eingaben: `sell(amountCents:)`, `refund(amountCents:)`,
    `requestTransactionV2Android(amountCents:, tipAmountCents:)`,
    `createTransactionIOS(amountCents:, tipAmountCents:)`.
  * Ergebnisse: `RequestResult.amountCents/tipAmountCents/totalAmountCents`,
    `InquireResult.amountCents/tipAmountCents/totalAmountCents` (neu),
    `Batch`/`SubBatch` mit `...AmountCents`.
  * Für Anzeigen gibt es `...Euro`-Getter (z. B. `amountEuro`).
* `InquireResult`-Betragsparsing vereinheitlicht: GPTom liefert dort
  Cent-Strings ("1111"), die jetzt konsistent als Cent interpretiert werden
  (vorher wurden numerische Werte ungeteilt durchgereicht).

## 0.0.2

* GPTom App2App AIDL-Bibliothek auf 1.29.0 aktualisiert (vorher 1.24.0).
* AIDL-Bibliothek liegt jetzt als Maven-Repo im Plugin (`android/repo`) –
  der Build funktioniert damit ohne `mavenLocal` auf jedem Rechner.
* Neu: Login-Service (`bindLoginService`, `loginGpTom`, `logoutGpTom`,
  `changeGpTomPassword`, `loginStatusStream`).
* Neu: Info-Service (`bindInfoService`, `getGpTomInfo`, `gpTomInfoStream`).
* Neu: `refund()` (transactionType 3, nur Android) und `unbindService()`.
* Fix: Beträge werden jetzt gerundet statt abgeschnitten – 4,35 EUR wurde
  vorher als 434 Cent gesendet.
* Fix: `transactionType` in der V2-Antwort wird über die GPTom-ID gemappt
  (vorher Enum-Index: SALE wurde als VOID geparst, CLOSE_BATCH crashte).
* Fix: `bindService` (Android) meldet erst dann Erfolg, wenn die
  Service-Verbindung tatsächlich steht; hängende Futures durch Timeout
  abgesichert; MethodChannel-Ergebnisse können nicht mehr doppelt
  beantwortet werden.
* Fix: iOS-Redirects werden vor dem Öffnen von GPTom abonniert, damit
  keine Antwort verpasst wird.
* Fix: Beträge in Antworten vertragen jetzt auch Double-Werte (1111.0).
* Transaktions- und Receipt-Daten werden nicht mehr geloggt.
* Tests für Betragsumrechnung, Response-Parsing und Enums ergänzt.

## 0.0.1

* Erste Version: registerTransactionV2, requestTransactionV2, stateRequest,
  inquireTransaction (Android via AIDL), Sale/Void/CloseBatch via
  URL-Scheme auf iOS.
