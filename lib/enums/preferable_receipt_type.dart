/// Bevorzugter Beleg-Typ.
///
/// GP tom erwartet je nach Schnittstelle unterschiedliche Werte:
/// - app2app/AIDL (Android, `ReceiptType`-Enum der AIDL-Bibliothek):
///   PHONE, EMAIL, QR, PRINT
/// - iOS-URL-Scheme: sms, email, qr, print
///
/// Achtung: Die deutsche Doku-Seite nennt lokalisierte Werte (TELEFON,
/// DRUCKEN) – das ist ein Übersetzungs-Artefakt. GP tom parst das JSON per
/// Gson gegen das ReceiptType-Enum; unbekannte Werte werden stillschweigend
/// verworfen.
enum PreferableReceiptType {
  telephone('PHONE', 'sms'),
  email('EMAIL', 'email'),
  qr('QR', 'qr'),
  print('PRINT', 'print');

  /// Wert für das app2app-JSON (AIDL, Android).
  final String aidlKey;

  /// Wert für das iOS-URL-Scheme.
  final String iosKey;

  const PreferableReceiptType(this.aidlKey, this.iosKey);

  @Deprecated('Plattformabhängig: aidlKey (Android) bzw. iosKey (iOS) nutzen.')
  String get key => aidlKey;
}
