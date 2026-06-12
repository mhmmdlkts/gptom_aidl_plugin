import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';

void main() {
  group('RequestResult.fromJson', () {
    test('parst eine erfolgreiche SALE-Antwort', () {
      final json = jsonEncode({
        'result': 0,
        'transactionID': 'tx-1',
        'amsID': 'ams-1',
        'amount': 1111,
        'tipAmount': 113,
        'totalAmount': 1224,
        'transactionType': 1,
        'approvedCode': '529625',
        'responseMessage': 'APPROVED',
        'cardNumber': '**** **** **** 7866',
        'currencyCode': 978,
        'pinOk': true,
        'merchantInfo': {
          'city': 'Bratislava',
          'company': 'Airspeed SK s.r.o.',
        },
      });

      final result = RequestResult.fromJson(json);

      expect(result.result, 0);
      expect(result.transactionId, 'tx-1');
      expect(result.amountCents, 1111);
      expect(result.tipAmountCents, 113);
      expect(result.totalAmountCents, 1224);
      expect(result.amountEuro, 11.11);
      expect(result.tipAmountEuro, 1.13);
      expect(result.transactionType, TransactionType.sell);
      expect(result.approvedCode, '529625');
      expect(result.currencyCode, '978');
      expect(result.pinOk, true);
      expect(result.merchantInfo?.city, 'Bratislava');
    });

    test('mappt transactionType über die GPTom-ID, nicht den Enum-Index', () {
      // 1=SALE, 2=VOID, 3=REFUND, 4=CLOSE_BATCH
      expect(
        RequestResult.fromJson('{"result":0,"transactionType":1}').transactionType,
        TransactionType.sell,
      );
      expect(
        RequestResult.fromJson('{"result":0,"transactionType":2}').transactionType,
        TransactionType.voidSell,
      );
      expect(
        RequestResult.fromJson('{"result":0,"transactionType":3}').transactionType,
        TransactionType.refund,
      );
      expect(
        RequestResult.fromJson('{"result":0,"transactionType":4}').transactionType,
        TransactionType.closeBatch,
      );
    });

    test('unbekannter oder fehlender transactionType wird null', () {
      expect(
        RequestResult.fromJson('{"result":0,"transactionType":99}').transactionType,
        isNull,
      );
      expect(
        RequestResult.fromJson('{"result":0}').transactionType,
        isNull,
      );
      expect(
        RequestResult.fromJson('{"result":0,"transactionType":"1"}').transactionType,
        isNull,
      );
    });

    test('verträgt Beträge als double (1111.0)', () {
      final result = RequestResult.fromJson('{"result":0,"amount":1111.0}');
      expect(result.amountCents, 1111);
    });

    test('parst das Fehler-Objekt', () {
      final json = jsonEncode({
        'result': -4,
        'error': {
          'errorCode': '1-097',
          'exception': 'SomeException',
          'supportID': 'To69eP',
        },
      });

      final result = RequestResult.fromJson(json);

      expect(result.result, -4);
      expect(result.error?.errorCode, '1-097');
      expect(result.error?.supportID, 'To69eP');
      expect(result.error?.errorMessage, 'Die Transaktion wurde abgelehnt.');
    });

    test('liefert result -1001 wenn das JSON keine Map ist', () {
      final result = RequestResult.fromJson('[1,2,3]');
      expect(result.result, -1001);
    });
  });
}
