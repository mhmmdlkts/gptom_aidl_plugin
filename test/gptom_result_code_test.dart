import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/gptom_result_code.dart';

/// Die aufrufende App entscheidet am Code, nicht an einer Zahl im eigenen
/// Quelltext. Deshalb müssen die Konstanten stabil, eindeutig und in die
/// beiden Gruppen "kann belastet sein" / "sicher nicht belastet" sortiert
/// sein.
void main() {
  test('Plugin-Codes sind eindeutig und stabil', () {
    final codes = <int>[
      GptomResultCode.success,
      GptomResultCode.exception,
      GptomResultCode.cannotOpen,
      GptomResultCode.timeout,
      GptomResultCode.noReceipt,
      GptomResultCode.parseError,
      GptomResultCode.cancelled,
    ];
    expect(codes.toSet().length, codes.length);

    // Stabil, weil Backend-Aufdruck und App-Protokolle darauf zeigen.
    expect(GptomResultCode.success, 0);
    expect(GptomResultCode.exception, -1001);
    expect(GptomResultCode.cannotOpen, -1002);
    expect(GptomResultCode.timeout, -1003);
    expect(GptomResultCode.noReceipt, -1004);
    expect(GptomResultCode.parseError, -1005);
    expect(GptomResultCode.cancelled, -1006);
  });

  test('unklare Ausgänge: Karte kann belastet sein', () {
    expect(GptomResultCode.istUnklar(GptomResultCode.timeout), isTrue);
    expect(GptomResultCode.istUnklar(GptomResultCode.noReceipt), isTrue);
    expect(GptomResultCode.istUnklar(GptomResultCode.parseError), isTrue);
    expect(GptomResultCode.istUnklar(GptomResultCode.exception), isTrue);
  });

  test('sichere Ausgänge: Karte wurde nicht belastet', () {
    // Nur diese beiden darf die App gefahrlos wiederholen.
    expect(GptomResultCode.istOhneBelastung(GptomResultCode.cannotOpen), isTrue);
    expect(GptomResultCode.istOhneBelastung(GptomResultCode.cancelled), isTrue);

    expect(GptomResultCode.istOhneBelastung(GptomResultCode.timeout), isFalse);
    expect(GptomResultCode.istOhneBelastung(GptomResultCode.noReceipt), isFalse);
    expect(GptomResultCode.istOhneBelastung(GptomResultCode.parseError), isFalse);
    expect(GptomResultCode.istOhneBelastung(null), isFalse);
  });

  test('Erfolg ist weder unklar noch "ohne Belastung"', () {
    expect(GptomResultCode.istUnklar(GptomResultCode.success), isFalse);
    expect(GptomResultCode.istOhneBelastung(GptomResultCode.success), isFalse);
  });

  test('Fehlerkennungen sind eindeutig', () {
    final codes = <String>[
      GptomErrorCode.timeout,
      GptomErrorCode.cannotOpen,
      GptomErrorCode.noReceipt,
      GptomErrorCode.parseError,
      GptomErrorCode.cancelled,
      GptomErrorCode.declined,
    ];
    expect(codes.toSet().length, codes.length);
    // Android-Wächter und iOS-Zeitablauf melden denselben Code.
    expect(GptomErrorCode.timeout, 'TIMEOUT');
  });

  test('unverified (-1007) ist unklar und nicht ohne Belastung', () {
    expect(GptomResultCode.istUnklar(-1007), isTrue);
    expect(GptomResultCode.istOhneBelastung(-1007), isFalse);
    expect(GptomErrorCode.unverified, 'UNVERIFIED');
  });
}
