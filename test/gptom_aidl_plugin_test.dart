import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/cancel_mode.dart';
import 'package:gptom_aidl_plugin/enums/preferable_receipt_type.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_platform_interface.dart';
import 'package:gptom_aidl_plugin/models/gptom_info.dart';
import 'package:gptom_aidl_plugin/models/inquire_result.dart';
import 'package:gptom_aidl_plugin/models/login_status.dart';
import 'package:gptom_aidl_plugin/models/register_result.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';
import 'package:gptom_aidl_plugin/models/state_result.dart';

class _FakePlatform extends GptomAidlPluginPlatform {
  Map<String, dynamic>? lastRequestParams;
  Map<String, dynamic>? lastRegisterParams;

  @override
  Future<bool> existGpTomApp({bool isDevAndroid = false}) async => true;

  @override
  Future<bool> bindService({bool isDevAndroid = false}) async => true;

  @override
  Future<void> unbindService() async {}

  @override
  Future<RegisterResult> registerTransactionV2Android(Map<String, dynamic> params) async {
    lastRegisterParams = params;
    return RegisterResult(resultCode: 0, transactionId: 'tx-1');
  }

  @override
  Future<RequestResult> requestTransactionV2Android(Map<String, dynamic> params) async {
    lastRequestParams = params;
    return RequestResult(result: 0);
  }

  @override
  Future<StateResult> stateRequestAndroid(String transactionId) async =>
      StateResult(resultCode: 0);

  @override
  Future<InquireResult> inquireTransactionAndroid(String transactionId) async =>
      InquireResult.exception();

  @override
  Future<bool> createTransactionIOS() async => true;

  @override
  Future<bool> cancelTransactionIOS() async => true;

  @override
  Future<bool> bindLoginService({bool isDevAndroid = false}) async => true;

  @override
  Future<void> unbindLoginService() async {}

  @override
  Future<bool> loginGpTom({
    required String username,
    required String password,
    required String terminalId,
    String? authCode,
  }) async =>
      true;

  @override
  Future<bool> logoutGpTom() async => true;

  @override
  Future<bool> changeGpTomPassword({
    required String currentPassword,
    required String newPassword,
    String? authCode,
    bool validationOnly = false,
  }) async =>
      true;

  @override
  Stream<GpTomLoginEvent> get loginStatusStream => const Stream.empty();

  @override
  Future<bool> bindInfoService({bool isDevAndroid = false}) async => true;

  @override
  Future<void> unbindInfoService() async {}

  @override
  Future<GpTomInfo?> getGpTomInfo() async => null;

  @override
  Stream<GpTomInfo> get gpTomInfoStream => const Stream.empty();
}

void main() {
  late _FakePlatform fake;
  late GptomAidlPlugin plugin;

  setUp(() {
    fake = _FakePlatform();
    GptomAidlPluginPlatform.instance = fake;
    plugin = GptomAidlPlugin();
  });

  group('Betragsumrechnung (EUR -> Cent)', () {
    test('rundet korrekt statt abzuschneiden', () async {
      // 4.35 * 100 ist als double 434.99999…, toInt() hätte 434 ergeben.
      await plugin.sell(
        transactionIdAndroid: 'tx-1',
        amount: 4.35,
        transactionMethode: TransactionMethode.card,
      );
      expect(fake.lastRequestParams!['amount'], 435);
    });

    test('weitere kritische Beträge', () async {
      final cases = {
        8.20: 820,
        1.13: 113,
        2.55: 255,
        11.11: 1111,
        0.07: 7,
        29.30: 2930,
      };
      for (final entry in cases.entries) {
        await plugin.requestTransactionV2Android(
          transactionId: 'tx-1',
          transactionType: TransactionType.sell,
          amount: entry.key,
        );
        expect(fake.lastRequestParams!['amount'], entry.value,
            reason: '${entry.key} EUR muss ${entry.value} Cent ergeben');
      }
    });

    test('tipAmount wird ebenfalls gerundet', () async {
      await plugin.sell(
        transactionIdAndroid: 'tx-1',
        amount: 10.00,
        tipAmount: 1.13,
        transactionMethode: TransactionMethode.card,
      );
      expect(fake.lastRequestParams!['tipAmount'], 113);
    });
  });

  group('sell', () {
    test('baut die Request-Parameter korrekt', () async {
      await plugin.sell(
        transactionIdAndroid: 'tx-1',
        amount: 11.11,
        transactionMethode: TransactionMethode.card,
        clientId: 'client-1',
        printByPaymentApp: true,
        tipCollect: true,
        preferableReceiptType: PreferableReceiptType.print,
      );
      final params = fake.lastRequestParams!;
      expect(params['transactionID'], 'tx-1');
      expect(params['transactionType'], TransactionType.sell.id);
      expect(params['amount'], 1111);
      expect(params['clientID'], 'client-1');
      expect(params['printByPaymentApp'], true);
      expect(params['tipCollect'], true);
      expect(params['openGptomUI'], true);
      // Wert kommt so aus der GPTom-API – nicht "korrigieren"
      expect(params['preferableReceiptType'], 'DRUCKEN');
    });

    test('wirft ohne transactionIdAndroid', () async {
      expect(
        () => plugin.sell(
          amount: 1.0,
          transactionMethode: TransactionMethode.card,
        ),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('voidSell', () {
    test('baut die Request-Parameter korrekt', () async {
      await plugin.voidSell(
        transactionIdAndroid: 'tx-2',
        originTransactionId: 'orig-1',
        cancelMode: CancelMode.last,
      );
      final params = fake.lastRequestParams!;
      expect(params['transactionType'], TransactionType.voidSell.id);
      expect(params['originTransactionID'], 'orig-1');
      expect(params['cancelMode'], CancelMode.last.id);
      expect(params.containsKey('amount'), isFalse);
    });

    test('wirft ohne transactionIdAndroid', () async {
      expect(
        () => plugin.voidSell(
          originTransactionId: 'orig-1',
          cancelMode: CancelMode.last,
        ),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('refund', () {
    test('baut die Request-Parameter korrekt', () async {
      await plugin.refund(
        transactionIdAndroid: 'tx-3',
        originTransactionId: 'orig-2',
        amount: 5.25,
      );
      final params = fake.lastRequestParams!;
      expect(params['transactionType'], TransactionType.refund.id);
      expect(params['transactionType'], 3);
      expect(params['originTransactionID'], 'orig-2');
      expect(params['amount'], 525);
    });

    test('wirft ohne transactionIdAndroid', () async {
      expect(
        () => plugin.refund(
          originTransactionId: 'orig-2',
          amount: 5.25,
        ),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('closeBatch', () {
    test('liefert das Ergebnis zurück und nutzt Typ 4', () async {
      final result = await plugin.closeBatch(transactionIdAndroid: 'tx-4');
      expect(fake.lastRequestParams!['transactionType'], TransactionType.closeBatch.id);
      expect(result, isA<RequestResult>());
      expect((result as RequestResult).result, 0);
    });

    test('wirft ohne transactionIdAndroid', () async {
      expect(
        () => plugin.closeBatch(),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('registerTransactionV2Android', () {
    test('gibt clientID weiter', () async {
      final result = await plugin.registerTransactionV2Android(clientId: 'client-9');
      expect(fake.lastRegisterParams!['clientID'], 'client-9');
      expect(result.transactionId, 'tx-1');
    });

    test('lässt clientID weg, wenn nicht gesetzt', () async {
      await plugin.registerTransactionV2Android();
      expect(fake.lastRegisterParams!.containsKey('clientID'), isFalse);
    });
  });
}
