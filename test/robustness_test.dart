import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/models/batch.dart';
import 'package:gptom_aidl_plugin/models/inquire_result.dart';
import 'package:gptom_aidl_plugin/models/register_result.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';
import 'package:gptom_aidl_plugin/models/state_result.dart';
import 'package:gptom_aidl_plugin/testing.dart';

/// GP tom Antworten sind Fremd-Input: kaputtes JSON oder fehlende Felder
/// dürfen nie zu einem Crash führen, sondern zu Fehler-Ergebnissen.
void main() {
  group('fromJson verträgt kaputten Input', () {
    test('RegisterResult', () {
      expect(RegisterResult.fromJson('kein json').resultCode, -1001);
      expect(RegisterResult.fromJson('[1,2]').resultCode, -1001);
      expect(RegisterResult.fromJson('{}').resultCode, -1001);
      // resultCode als String wird toleriert
      expect(RegisterResult.fromJson('{"resultCode":"0"}').resultCode, 0);
    });

    test('RequestResult', () {
      expect(RequestResult.fromJson('kein json').result, -1001);
      expect(RequestResult.fromJson('42').result, -1001);
    });

    test('StateResult', () {
      expect(StateResult.fromJson('kein json').resultCode, -1001);
      expect(StateResult.fromJson('null').resultCode, -1001);
    });

    test('InquireResult', () {
      expect(InquireResult.fromJson('kein json').result, -1001);
      expect(InquireResult.fromJson('"text"').result, -1001);
    });
  });

  group('RegisterResult', () {
    test('isSuccess nur bei resultCode 0 und vorhandener transactionId', () {
      expect(
        RegisterResult(resultCode: 0, transactionId: 'tx-1').isSuccess,
        isTrue,
      );
      expect(RegisterResult(resultCode: 0).isSuccess, isFalse);
      expect(
        RegisterResult(resultCode: -7, transactionId: 'tx-1').isSuccess,
        isFalse,
      );
    });

    test('parst das error-Objekt', () {
      final result = RegisterResult.fromJson(
        '{"resultCode":-1,"error":{"errorCode":"1-097","supportID":"To69eP"}}',
      );
      expect(result.error?.errorCode, '1-097');
      expect(result.error?.supportID, 'To69eP');
    });
  });

  group('InquireResult transactionType', () {
    test('mappt über die GPTom-ID inkl. Fallback-Key', () {
      expect(
        InquireResult.fromJson('{"result":0,"transacitonType":4}').transactionType,
        TransactionType.closeBatch,
      );
      expect(
        InquireResult.fromJson('{"result":0,"transactionType":2}').transactionType,
        TransactionType.voidSell,
      );
      expect(
        InquireResult.fromJson('{"result":0,"transacitonType":99}').transactionType,
        isNull,
      );
    });
  });

  group('Batch defensives Parsen', () {
    test('fehlende Felder werden zu Defaults statt zu werfen', () {
      final batch = Batch.fromJson({});
      expect(batch.saleCount, 0);
      expect(batch.totalAmountCents, 0);
      expect(batch.subBatches, isEmpty);
      expect(batch.amsId, '');
      expect(batch.isSuccess, isFalse);
      expect(batch.subBatch('CARD'), isNull);
    });

    test('SubBatch.exists reagiert auf Transaktionen oder Betrag', () {
      SubBatch sub({int totalCount = 0, num totalAmount = 0}) =>
          SubBatch.fromJson({'totalCount': totalCount, 'totalAmount': totalAmount});
      expect(sub().exists, isFalse);
      expect(sub(totalCount: 1).exists, isTrue);
      expect(sub(totalAmount: 4.35).exists, isTrue);
    });

    test('numerische Strings werden toleriert', () {
      final batch = Batch.fromJson({
        'saleCount': '3',
        'saleAmount': '95.5',
        'date': '2026-07-07T18:00:00.000Z',
      });
      expect(batch.saleCount, 3);
      expect(batch.saleAmountCents, 9550);
    });
  });

  group('Eingabe-Validierung', () {
    late FakeGptomAidlPluginPlatform fake;
    late GptomAidlPlugin plugin;

    setUp(() {
      fake = FakeGptomAidlPluginPlatform();
      GptomAidlPluginPlatform.instance = fake;
      plugin = GptomAidlPlugin();
    });

    test('sell wirft bei Betrag <= 0', () {
      expect(
        () => plugin.sell(
          transactionIdAndroid: 'tx-1',
          amountCents: 0,
          transactionMethode: TransactionMethode.card,
        ),
        throwsArgumentError,
      );
      expect(
        () => plugin.sell(
          transactionIdAndroid: 'tx-1',
          amountCents: -100,
          transactionMethode: TransactionMethode.card,
        ),
        throwsArgumentError,
      );
      expect(fake.requestCalls, isEmpty);
    });

    test('sell wirft bei negativem Trinkgeld', () {
      expect(
        () => plugin.sell(
          transactionIdAndroid: 'tx-1',
          amountCents: 100,
          tipAmountCents: -1,
          transactionMethode: TransactionMethode.card,
        ),
        throwsArgumentError,
      );
    });

    test('refund wirft bei Betrag <= 0', () {
      expect(
        () => plugin.refund(
          transactionIdAndroid: 'tx-1',
          originTransactionId: 'orig-1',
          amountCents: 0,
        ),
        throwsArgumentError,
      );
    });
  });

  group('Fake-Szenario-Handler', () {
    test('onRequest: erst abgelehnt, dann erfolgreich', () async {
      final fake = FakeGptomAidlPluginPlatform();
      GptomAidlPluginPlatform.instance = fake;
      final plugin = GptomAidlPlugin();

      var calls = 0;
      fake.onRequest = (params) => RequestResult(result: ++calls == 1 ? -4 : 0);

      final first = await plugin.sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
      );
      final second = await plugin.sell(
        transactionIdAndroid: 'tx-2',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
      );

      expect(first.result, -4);
      expect(second.result, 0);
      expect(fake.requestCalls, hasLength(2));
    });

    test('onStateRequest: Status-Verlauf simulieren', () async {
      final fake = FakeGptomAidlPluginPlatform();
      GptomAidlPluginPlatform.instance = fake;
      final plugin = GptomAidlPlugin();

      final states = [StateStatus.inProgress, StateStatus.completed];
      var i = 0;
      fake.onStateRequest =
          (id) => StateResult(resultCode: 0, state: states[i++]);

      expect((await plugin.stateRequestAndroid('tx')).state, StateStatus.inProgress);
      expect((await plugin.stateRequestAndroid('tx')).state, StateStatus.completed);
    });
  });
}
