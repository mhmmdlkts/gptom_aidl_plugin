import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/models/register_result.dart';

void main() {
  group('RegisterResult.fromJson', () {
    test('parst eine erfolgreiche Antwort', () {
      final json = jsonEncode({
        'resultCode': 0,
        'transactionId': 'tx-1',
        'clientID': 'client-1',
        'responseMessage': 'OK',
      });

      final result = RegisterResult.fromJson(json);

      expect(result.resultCode, 0);
      expect(result.transactionId, 'tx-1');
      expect(result.clientID, 'client-1');
      expect(result.responseMessage, 'OK');
    });

    test('optionale Felder dürfen fehlen', () {
      final result = RegisterResult.fromJson('{"resultCode":-1}');
      expect(result.resultCode, -1);
      expect(result.transactionId, isNull);
    });
  });
}
