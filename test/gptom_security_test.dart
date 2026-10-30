import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/gptom_security.dart';

void main() {
  const hex = 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12';
  const erwartet =
      'AB:12:CD:34:EF:56:AB:12:CD:34:EF:56:AB:12:CD:34:EF:56:AB:12:CD:34:EF:56:AB:12:CD:34:EF:56:AB:12';

  test('klein ohne Doppelpunkte wird groß mit Doppelpunkten', () {
    expect(GptomSecurityConfig.normalizeFingerprint(hex), erwartet);
  });

  test('Leerzeichen und Bindestriche werden entfernt', () {
    final mitTrennern = hex.replaceAllMapped(RegExp('..'), (m) => '${m[0]}-');
    expect(
        GptomSecurityConfig.normalizeFingerprint(' $mitTrennern '), erwartet);
    expect(GptomSecurityConfig.normalizeFingerprint(erwartet), erwartet);
  });

  test('63 Zeichen sind ungültig', () {
    expect(() => GptomSecurityConfig.normalizeFingerprint(hex.substring(1)),
        throwsArgumentError);
  });

  test('keine Hex-Zeichen sind ungültig', () {
    expect(() => GptomSecurityConfig.normalizeFingerprint('XY' * 32),
        throwsArgumentError);
  });

  test('Standardwerte', () {
    const c = GptomSecurityConfig();
    expect(c.verifySignatureAndroid, isTrue);
    expect(c.trustedSignaturesAndroid, isEmpty);
    expect(c.allowDevPackageInRelease, isFalse);
    expect(c.redirectTokenIOS, isTrue);
    expect(c.sendRequestIdIOS, isTrue);
    expect(GptomSecurityConfig.current.verifySignatureAndroid, isTrue);
  });

  test('normalizedSignaturesAndroid normalisiert alle Pins', () {
    final c = GptomSecurityConfig(trustedSignaturesAndroid: [hex]);
    expect(c.normalizedSignaturesAndroid, [erwartet]);
  });
}
