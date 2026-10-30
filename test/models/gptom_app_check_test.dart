import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/models/gptom_app_check.dart';

void main() {
  test('fromMap mit allen Keys', () {
    final c = GptomAppCheck.fromMap({
      'installed': true,
      'trusted': true,
      'source': 'pinned',
      'signatureSha256': ['AB:CD', 'EF:01'],
      'versionName': '1.80.0',
      'versionCode': 180,
    });
    expect(c.installed, isTrue);
    expect(c.trusted, isTrue);
    expect(c.source, GptomTrustSource.pinned);
    expect(c.signatureSha256, ['AB:CD', 'EF:01']);
    expect(c.versionName, '1.80.0');
    expect(c.versionCode, 180);
  });

  test('unbekannte Quelle wird mismatch', () {
    final c = GptomAppCheck.fromMap(
        {'installed': true, 'trusted': true, 'source': 'quatsch'});
    expect(c.source, GptomTrustSource.mismatch);
    expect(c.signatureSha256, isEmpty);
  });

  test('alle Quellen sind über den Namen lesbar', () {
    for (final s in GptomTrustSource.values) {
      expect(
          GptomAppCheck.fromMap(
                  {'installed': false, 'trusted': false, 'source': s.name})
              .source,
          s);
    }
  });
}
