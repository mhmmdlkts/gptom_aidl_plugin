import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/models/inquire_result.dart';

void main() {
  group('InquireResult.fromJson', () {
    test('liest die GPTom-Keys inkl. der API-Tippfehler', () {
      // "trasanctionID" und "transacitonType" sind KEINE Tippfehler im Test:
      // GPTom liefert diese Keys exakt so. Nicht "korrigieren".
      final json = jsonEncode({
        'result': 0,
        'trasanctionID': 'tx-1',
        'transacitonType': 1,
        'approvedCode': '529625',
        'merchantID': '000007311211351',
        'terminalID': '11263520',
        'amount': 11.11,
        'tipAmount': 0.0,
        'currencyCode': 'EUR',
        'cardNumber': '**** **** **** 7866',
        'emvAppLable': 'VISA CREDIT',
        'pinOk': false,
      });

      final result = InquireResult.fromJson(json);

      expect(result.result, 0);
      expect(result.transactionId, 'tx-1');
      expect(result.transactionType, TransactionType.sell);
      expect(result.amount, 11.11);
      expect(result.emvAppLable, 'VISA CREDIT');
      expect(result.terminalID, '11263520');
    });

    test('verträgt fehlende trasanctionID', () {
      final result = InquireResult.fromJson('{"result":-3,"amount":0,"tipAmount":0}');
      expect(result.result, -3);
      expect(result.transactionId, '');
    });

    test('parst Beträge aus Strings (Cent-Format)', () {
      final result = InquireResult.fromJson(jsonEncode({
        'result': 0,
        'trasanctionID': 'tx-1',
        'amount': '1111',
        'tipAmount': '113',
      }));
      expect(result.amount, 11.11);
      expect(result.tipAmount, 1.13);
    });

    test('parst das Fehler-Objekt', () {
      final result = InquireResult.fromJson(jsonEncode({
        'result': -1,
        'trasanctionID': 'tx-1',
        'amount': 0,
        'tipAmount': 0,
        'error': {
          'errorCode': '1-038',
          'exception': 'XYZException',
          'supportID': 'Ca38A8',
        },
      }));
      expect(result.error?.errorCode, '1-038');
      expect(result.error?.supportID, 'Ca38A8');
    });

    test('toMap nutzt die GPTom-Keys (inkl. Tippfehler) unverändert', () {
      final result = InquireResult.fromJson(jsonEncode({
        'result': 0,
        'trasanctionID': 'tx-1',
        'transacitonType': 2,
        'amount': 0,
        'tipAmount': 0,
      }));
      final map = result.toMap();
      expect(map['trasanctionID'], 'tx-1');
      expect(map['transacitonType'], 2);
    });
  });
}
