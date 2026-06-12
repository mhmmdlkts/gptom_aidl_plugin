import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/models/batch.dart';

Map<String, dynamic> _subBatch({double saleAmount = 10.0}) => {
      'voidCount': 1,
      'totalCount': 3,
      'saleAmount': saleAmount,
      'voidAmount': 2.0,
      'saleCount': 2,
      'closeBatchNumber': '42',
      'totalAmount': saleAmount - 2.0,
    };

Map<String, dynamic> _batchMap() => {
      'saleCount': 5,
      'previousBatchDate': '2026-05-18T10:00:00.000Z',
      'voidCount': 1,
      'firstTransactionDate': '2026-05-19T08:00:00.000Z',
      'saleAmount': 100.5,
      'invalidCount': 0,
      'communicationId': 'comm-1',
      'date': '2026-05-19T20:00:00.000Z',
      'totalCount': 6,
      'voidAmount': 5.0,
      'subBatches': {
        'CARD': _subBatch(saleAmount: 80.0),
        'CASH': _subBatch(saleAmount: 20.5),
        'GO_CRYPTO': _subBatch(saleAmount: 0),
        'ACCOUNT_PAYMENT': _subBatch(saleAmount: 0),
      },
      'currency': 'EUR',
      'totalAmount': 95.5,
      'amsId': 'ams-1',
    };

void main() {
  group('Batch', () {
    test('fromJson parst alle Felder und rechnet Euro in Cent um', () {
      final batch = Batch.fromJson(_batchMap());

      expect(batch.saleCount, 5);
      expect(batch.voidCount, 1);
      expect(batch.saleAmountCents, 10050);
      expect(batch.totalAmountCents, 9550);
      expect(batch.saleAmountEuro, 100.5);
      expect(batch.currency, 'EUR');
      expect(batch.amsId, 'ams-1');
      expect(batch.isSuccess, isTrue);
      expect(batch.date, DateTime.parse('2026-05-19T20:00:00.000Z'));
      expect(batch.cardBatch.saleAmountCents, 8000);
      expect(batch.cashBatch.saleAmountCents, 2050);
      expect(batch.cardBatch.closeBatchNumber, '42');
    });

    test('toJson/fromJson sind verlustfrei (Euro-Format auf dem Draht)', () {
      final batch = Batch.fromJson(_batchMap());
      final roundTripped = Batch.fromJson(jsonDecode(jsonEncode(batch.toJson())));
      expect(roundTripped.saleAmountCents, batch.saleAmountCents);
      expect(roundTripped.totalAmountCents, batch.totalAmountCents);
      expect(roundTripped.cardBatch.saleAmountCents, batch.cardBatch.saleAmountCents);
    });

    test('fromQuery parst einen JSON-String', () {
      final batch = Batch.fromQuery(jsonEncode(_batchMap()));
      expect(batch.amsId, 'ams-1');
    });

    test('optionale Daten dürfen null sein', () {
      final map = _batchMap()
        ..['previousBatchDate'] = null
        ..['firstTransactionDate'] = null;
      final batch = Batch.fromJson(map);
      expect(batch.previousBatchDate, isNull);
      expect(batch.firstTransactionDate, isNull);
    });

    test('compareTo sortiert nach Datum', () {
      final older = Batch.fromJson(_batchMap()..['date'] = '2026-05-18T20:00:00.000Z');
      final newer = Batch.fromJson(_batchMap());
      expect(older.compareTo(newer), lessThan(0));
    });
  });
}
