/// Woher das Vertrauen in die GP tom App kommt (Android-Signaturprüfung).
enum GptomTrustSource {
  /// Fingerprint stimmt mit einem konfigurierten Pin überein.
  pinned,

  /// Kein Pin konfiguriert, erster Fingerprint gemerkt (trust on first use).
  firstUse,

  /// Signatur passt nicht.
  mismatch,

  /// Prüfung abgeschaltet.
  unchecked,
  notInstalled,

  /// iOS: es gibt keine Signaturprüfung.
  notApplicable,

  /// Dev-Paket in einem Release-Build gesperrt.
  devPackageBlocked,
}

/// Ergebnis der Prüfung der GP tom App.
class GptomAppCheck {
  final bool installed;
  final bool trusted;
  final GptomTrustSource source;

  /// SHA-256 der Signatur-Zertifikate, Großbuchstaben, mit Doppelpunkten.
  final List<String> signatureSha256;
  final String? versionName;
  final int? versionCode;

  const GptomAppCheck({
    required this.installed,
    required this.trusted,
    required this.source,
    this.signatureSha256 = const [],
    this.versionName,
    this.versionCode,
  });

  factory GptomAppCheck.fromMap(Map<dynamic, dynamic> map) {
    final quelle = GptomTrustSource.values
        .where((e) => e.name == map['source'])
        .firstOrNull;
    final signaturen = map['signatureSha256'];
    final version = map['versionCode'];
    return GptomAppCheck(
      installed: map['installed'] == true,
      trusted: map['trusted'] == true,
      // Unbekannte Quelle nie als vertrauenswürdig lesen.
      source: quelle ?? GptomTrustSource.mismatch,
      signatureSha256:
          signaturen is List ? signaturen.map((e) => e.toString()).toList() : const [],
      versionName: map['versionName'] as String?,
      versionCode: version is num ? version.toInt() : null,
    );
  }
}
