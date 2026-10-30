/// Einstellungen zur Absicherung gegen gefälschte Apps und Redirects.
class GptomSecurityConfig {
  /// Android: Signatur der GP tom App vor jedem Zugriff prüfen.
  final bool verifySignatureAndroid;

  /// Android: erlaubte SHA-256-Fingerprints der Signatur. Leer = trust on
  /// first use.
  final List<String> trustedSignaturesAndroid;

  /// Android: das Dev-Paket (`.dev`) auch in Release-Builds zulassen.
  final bool allowDevPackageInRelease;

  /// iOS: geheimes Einmal-Token in der Redirect-URL.
  final bool redirectTokenIOS;

  /// iOS: beim Verkauf eine `requestID` mitschicken.
  final bool sendRequestIdIOS;

  const GptomSecurityConfig({
    this.verifySignatureAndroid = true,
    this.trustedSignaturesAndroid = const [],
    this.allowDevPackageInRelease = false,
    this.redirectTokenIOS = true,
    this.sendRequestIdIOS = true,
  });

  /// Die gerade gültige Konfiguration.
  static GptomSecurityConfig current = const GptomSecurityConfig();

  /// Bringt einen Fingerprint auf die Form `AB:CD:…` (64 Hex-Zeichen).
  /// Trenner (`:`, Leerzeichen, `-`) und Schreibweise sind egal.
  static String normalizeFingerprint(String input) {
    final hex = input.replaceAll(RegExp(r'[:\s-]'), '').toUpperCase();
    if (!RegExp(r'^[0-9A-F]{64}$').hasMatch(hex)) {
      throw ArgumentError(
          'Ungültiger SHA-256-Fingerprint: erwartet werden 64 Hex-Zeichen.');
    }
    final paare = <String>[
      for (var i = 0; i < hex.length; i += 2) hex.substring(i, i + 2),
    ];
    return paare.join(':');
  }

  /// [trustedSignaturesAndroid] normalisiert. Wirft [ArgumentError] bei
  /// einem ungültigen Pin.
  List<String> get normalizedSignaturesAndroid =>
      trustedSignaturesAndroid.map(normalizeFingerprint).toList();
}
