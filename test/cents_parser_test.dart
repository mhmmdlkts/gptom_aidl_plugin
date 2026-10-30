import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/src/cents_parser.dart';

void main() {
  group('centsFromDecimal', () {
    final erwartungen = <Object?, int?>{
      '4.35': 435,
      '4,35': 435,
      '1 234,50': 123450,
      '1.234,50': 123450,
      '1,234.50': 123450,
      '10': 1000,
      '4.5': 450,
      '1.234': 123400,
      '1,234': 123400,
      '1.234.567': 123456700,
      '4.355': 435500,
      '4.3549': 435,
      '4.3550': 436,
      '-4.35': -435,
      '-4.3550': -436,
      4.35: 435,
      95.5: 9550,
      10: 1000,
      1.234: 123,
      '': null,
      'abc': null,
      '4,35 €': null,
      'EUR 4.35': null,
      '--4': null,
      // Tausender-Gruppen müssen genau drei Ziffern haben, die erste Gruppe
      // ein bis drei Ziffern ohne führende Null.
      '1.2.3,4': null,
      '1,2,3.4': null,
      '1.234.56': null,
      '1.234.567,89': 123456789,
      '12.345,67': 1234567,
      // Eine 0 vorne ist keine Tausender-Gruppe: Dezimalzeichen, gerundet.
      '0,995': 100,
      '0.995': 100,
      '0.123,45': null,
    };

    erwartungen.forEach((eingabe, erwartet) {
      test('${eingabe.runtimeType} "$eingabe" -> $erwartet', () {
        expect(centsFromDecimal(eingabe), erwartet);
      });
    });

    test('0.1 + 0.2 ergibt 30', () {
      expect(centsFromDecimal(0.1 + 0.2), 30);
    });

    test('null ergibt null', () {
      expect(centsFromDecimal(null), isNull);
    });

    test('Exponent-Schreibweise ergibt null', () {
      expect(centsFromDecimal(1e21), isNull);
    });
  });
}
