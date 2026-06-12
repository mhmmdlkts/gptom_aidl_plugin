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
