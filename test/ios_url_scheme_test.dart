import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/preferable_receipt_type.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';

/// Prüft die iOS-URL-Scheme-Seite: welche URLs an GP tom gehen und wie die
/// Redirect-Antworten (Receipt/Batch) geparst werden.
void main() {
  group('buildCreateTransactionUri', () {
    test('enthält alle Beleg-/Transaktionsdaten im GPTom-Format', () {
      final uri = GptomAidlPluginIOS.buildCreateTransactionUri(
        amountCents: 435,
        tipAmountCents: 50,
        redirectUrl: 'myapp://redirect',
        transactionMethode: TransactionMethode.card,
        clientID: 'client-1',
        originReferenceNum: 'RE-2026-001',
        printByPaymentApp: false,
        preferableReceiptType: PreferableReceiptType.telephone,
        clientPhone: '+436601234567',
        clientEmail: 'kunde@example.com',
        tipCollect: true,
      );

      expect(uri.scheme, 'gptom');
      expect(uri.host, 'transaction');
      expect(uri.path, '/create');

      final q = uri.queryParameters;
      // Betrag im *100-Format (Cent), als String im Query
      expect(q['amount'], '435');
      expect(q['tipAmount'], '50');
      expect(q['redirectUrl'], 'myapp://redirect');
      expect(q['clientID'], 'client-1');
      expect(q['originReferenceNum'], 'RE-2026-001');
      expect(q['printByPaymentApp'], 'false');
      // iOS-Doku: sms, email, qr, print
      expect(q['preferableReceiptType'], 'sms');
      expect(q['clientPhone'], '+436601234567');
      expect(q['clientEmail'], 'kunde@example.com');
      expect(q['tipCollect'], 'true');
      expect(q['transactionType'], 'CARD');
    });

    test('lässt optionale Parameter weg', () {
      final uri = GptomAidlPluginIOS.buildCreateTransactionUri(
        amountCents: 100,
        redirectUrl: 'myapp://redirect',
        transactionMethode: TransactionMethode.cash,
      );

      final q = uri.queryParameters;
      expect(q.containsKey('clientID'), isFalse);
      expect(q.containsKey('preferableReceiptType'), isFalse);
      expect(q.containsKey('clientPhone'), isFalse);
      expect(q.containsKey('clientEmail'), isFalse);
      expect(q.containsKey('tipAmount'), isFalse);
      expect(q['transactionType'], 'CASH');
      // Defaults laut Doku
      expect(q['printByPaymentApp'], 'true');
      expect(q['tipCollect'], 'false');
    });
  });

  group('buildCancelTransactionUri', () {
    test('enthält amsID und Beleg-Daten', () {
      final uri = GptomAidlPluginIOS.buildCancelTransactionUri(
        amsID: 'ams-123',
        redirectUrl: 'myapp://redirect',
        preferableReceiptType: PreferableReceiptType.print,
        clientEmail: 'kunde@example.com',
      );

      expect(uri.host, 'transaction');
      expect(uri.path, '/cancel');
      final q = uri.queryParameters;
      expect(q['amsID'], 'ams-123');
      expect(q['preferableReceiptType'], 'print');
      expect(q['clientEmail'], 'kunde@example.com');
      expect(q['redirectUrl'], 'myapp://redirect');
    });
  });

  group('buildCloseBatchUri', () {
    test('enthält Beleg-Daten', () {
      final uri = GptomAidlPluginIOS.buildCloseBatchUri(
        redirectUrl: 'myapp://redirect',
        clientID: 'client-1',
        preferableReceiptType: PreferableReceiptType.qr,
        clientPhone: '+436601234567',
      );

      expect(uri.host, 'batch');
      expect(uri.path, '/close');
      final q = uri.queryParameters;
      expect(q['clientID'], 'client-1');
      expect(q['preferableReceiptType'], 'qr');
      expect(q['clientPhone'], '+436601234567');
      expect(q['printByPaymentApp'], 'true');
    });
  });

  group('requestResultFromCreateRedirect', () {
    Uri redirectWithReceipt(Map<String, dynamic> receipt, {String status = 'COMPLETED'}) {
      return Uri(
        scheme: 'myapp',
        host: 'redirect',
        queryParameters: {
          'status': status,
          'receipt': jsonEncode(receipt),
        },
      );
    }

    test('parst das Receipt inkl. Euro-Dezimalbeträgen in Cent', () {
      final uri = redirectWithReceipt({
        'result': 0,
        'amsID': 'ams-1',
        'transactionID': 'gp-1',
        // GPTom liefert im iOS-Receipt Euro-Dezimalwerte
        'amount': '4.35',
        'tipAmount': '0.50',
        'totalAmount': '4.85',
        'authorizationCode': '529625',
        'batchNumber': '42',
        'sequenceNumber': '7',
        'terminalID': '11263520',
        'cardNumber': '7866',
        'cardType': 'VISA',
        'currencyCode': 'EUR',
        'pinOk': true,
        'emvAppLabel': 'Visa Debit',
        'emvAid': 'A0000000031010',
        'cardEntryMode': 'CTLS',
        'date': '2025-01-17T12:10:32',
      });

      final result = GptomAidlPluginIOS.requestResultFromCreateRedirect(
        uri,
        printByPaymentApp: true,
      );

      expect(result.result, 0);
      // Bei create ist die "eigene" ID die amsID
      expect(result.transactionId, 'ams-1');
      expect(result.externalTransactionID, 'gp-1');
      expect(result.amountCents, 435);
      expect(result.tipAmountCents, 50);
      expect(result.totalAmountCents, 485);
      expect(result.approvedCode, '529625');
      expect(result.cardNumber, '**** **** **** 7866');
      expect(result.cardProduct, 'VISA');
      expect(result.responseMessage, 'COMPLETED');
      expect(result.date, '170125');
      expect(result.time, '121032');
      expect(result.pinOk, isTrue);
      expect(result.transactionType, TransactionType.sell);
      expect(result.emvAppLable, 'Visa Debit');
      expect(result.cardDataEntry, 'CTLS');
    });

    test('liefert -1004, wenn kein Receipt im Redirect steckt', () {
      final result = GptomAidlPluginIOS.requestResultFromCreateRedirect(
        Uri.parse('myapp://redirect?status=ERROR'),
        printByPaymentApp: true,
      );
      expect(result.result, -1004);
    });
  });

  group('requestResultFromCancelRedirect', () {
    test('vertauscht amsID/transactionID gegenüber create', () {
      final uri = Uri(
        scheme: 'myapp',
        host: 'redirect',
        queryParameters: {
          'status': 'COMPLETED',
          'receipt': jsonEncode({
            'result': 0,
            'amsID': 'ams-1',
            'transactionID': 'gp-1',
            'amount': '4.35',
          }),
        },
      );

      final result = GptomAidlPluginIOS.requestResultFromCancelRedirect(
        uri,
        printByPaymentApp: true,
      );

      expect(result.transactionId, 'gp-1');
      expect(result.externalTransactionID, 'ams-1');
      expect(result.amsID, 'ams-1');
      expect(result.transactionType, TransactionType.voidSell);
    });
  });

  group('batchFromRedirect', () {
    test('parst den Batch aus dem Redirect (Euro-Dezimal -> Cent)', () {
      final batchJson = {
        'saleCount': 3,
        'previousBatchDate': '2026-07-06T18:00:00.000Z',
        'voidCount': 1,
        'firstTransactionDate': '2026-07-07T08:15:00.000Z',
        'saleAmount': 95.5,
        'invalidCount': 0,
        'communicationId': 'comm-1',
        'date': '2026-07-07T18:00:00.000Z',
        'totalCount': 4,
        'voidAmount': 4.35,
        'subBatches': {
          'CARD': {
            'voidCount': 1,
            'totalCount': 4,
            'saleAmount': 95.5,
            'voidAmount': 4.35,
            'saleCount': 3,
            'closeBatchNumber': '42',
            'totalAmount': 91.15,
          },
        },
        'currency': 'EUR',
        'totalAmount': 91.15,
        'amsId': 'ams-batch-1',
      };
      final uri = Uri(
        scheme: 'myapp',
        host: 'redirect',
        queryParameters: {'batch': jsonEncode(batchJson)},
      );

      final batch = GptomAidlPluginIOS.batchFromRedirect(uri);

      expect(batch.saleAmountCents, 9550);
      expect(batch.voidAmountCents, 435);
      expect(batch.totalAmountCents, 9115);
      expect(batch.cardBatch.totalAmountCents, 9115);
      expect(batch.amsId, 'ams-batch-1');
      expect(batch.isSuccess, isTrue);
    });

    test('wirft, wenn kein Batch im Redirect steckt', () {
      expect(
        () => GptomAidlPluginIOS.batchFromRedirect(Uri.parse('myapp://redirect')),
        throwsException,
      );
    });
  });
}
