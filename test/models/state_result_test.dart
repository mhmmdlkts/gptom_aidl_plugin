import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/models/state_result.dart';

void main() {
  group('StateResult.fromJson', () {
    test('parst einen COMPLETED-Status', () {
      final json = jsonEncode({
        'resultCode': 0,
        'transactionId': 'tx-1',
        'state': 6,
        'isRepeatable': false,
        'created': '2026-05-19T12:29:11.300Z',
        'updated': '2026-05-19T12:30:00.000Z',
      });

      final result = StateResult.fromJson(json);

      expect(result.resultCode, 0);
      expect(result.transactionId, 'tx-1');
      expect(result.state, StateStatus.completed);
      expect(result.state.finished, isTrue);
      expect(result.created, DateTime.parse('2026-05-19T12:29:11.300Z'));
    });

    test('alle bekannten Status-Werte', () {
      final expected = {
        1: StateStatus.created,
        2: StateStatus.started,
        3: StateStatus.initError,
        5: StateStatus.inProgress,
        6: StateStatus.completed,
        7: StateStatus.cancelled,
        8: StateStatus.error,
      };
      for (final entry in expected.entries) {
        final result = StateResult.fromJson('{"resultCode":0,"state":${entry.key}}');
        expect(result.state, entry.value, reason: 'state ${entry.key}');
      }
    });

    test('unbekannter Status wird unknown', () {
      final result = StateResult.fromJson('{"resultCode":0,"state":99}');
      expect(result.state, StateStatus.unknown);
    });

    test('resultCode als String wird geparst', () {
      final result = StateResult.fromJson('{"resultCode":"0","state":6}');
      expect(result.resultCode, 0);
    });

    test('Fehler-Objekt und Retry-Logik', () {
      final result = StateResult.fromJson(jsonEncode({
        'resultCode': -1,
        'state': 8,
        'error': {
          'code': 65,
          'internalErrorCode': 1,
          'internalErrorSubCode': 2,
          'platform': 'android',
        },
      }));
      expect(result.error?.code, 65);
      expect(result.error?.errorMessage, 'Transaktion abgelaufen.');
      expect(result.error?.isRetryable, isTrue);

      final tech = StateErrorResult(code: 104);
      expect(tech.isRetryable, isTrue);

      final other = StateErrorResult(code: 1);
      expect(other.isRetryable, isFalse);
    });
  });
}
