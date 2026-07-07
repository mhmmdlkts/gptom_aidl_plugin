import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/preferable_receipt_type.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_method_channel.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_platform_interface.dart';

/// Prüft das JSON, das tatsächlich über den MethodChannel an die native
/// Seite geht – also genau das, was (bis auf die Steuerfelder) 1:1 an die
/// GP tom App weitergereicht wird.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('gptom_aidl_plugin');

  final List<MethodCall> nativeCalls = [];
  Object? Function(MethodCall call)? nativeAnswer;

  setUp(() {
    nativeCalls.clear();
    nativeAnswer = null;
    MethodChannelGptomAidlPlugin.debugBypassPlatformChecks = true;
    GptomAidlPluginPlatform.instance = MethodChannelGptomAidlPlugin();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return nativeAnswer?.call(call);
    });
  });

  tearDown(() {
    MethodChannelGptomAidlPlugin.debugBypassPlatformChecks = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Map<String, dynamic> sentRequestJson() {
    final call = nativeCalls.singleWhere((c) => c.method == 'requestTransactionV2');
    final args = Map<String, dynamic>.from(call.arguments as Map);
    return Map<String, dynamic>.from(jsonDecode(args['requestJson'] as String));
  }

  group('requestTransactionV2-Wire-Format', () {
    test('Beleg-Daten landen exakt im GPTom-Format im JSON', () async {
      nativeAnswer = (call) => jsonEncode({'result': 0});

      await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 435,
        tipAmountCents: 50,
        transactionMethode: TransactionMethode.card,
        printByPaymentApp: false,
        tipCollect: true,
        preferableReceiptType: PreferableReceiptType.email,
        clientInfo: {
          'email': 'kunde@example.com',
          'phone': '+436601234567',
        },
      );

      final json = sentRequestJson();
      // Keys/Werte wie in TransactionRequestV2Entity (Gson, kein
      // SerializedName): exakte Schreibweise ist hier entscheidend.
      expect(json['transactionID'], 'tx-1');
      expect(json['transactionType'], 1);
      expect(json['amount'], 435);
      expect(json['amount'], isA<int>());
      expect(json['tipAmount'], 50);
      expect(json['printByPaymentApp'], false);
      expect(json['tipCollect'], true);
      expect(json['preferableReceiptType'], 'EMAIL');
      expect(json['clientInfo'], {
        'contact': {
          'email': 'kunde@example.com',
          'phone': '+436601234567',
        },
      });
    });

    test('openGptomUI wird mitgesendet (nativer Code entfernt es wieder)', () async {
      nativeAnswer = (call) => jsonEncode({'result': 0});

      await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
        openGptomUI: false,
      );

      expect(sentRequestJson()['openGptomUI'], false);
    });

    test('optionale Felder fehlen komplett statt null zu sein', () async {
      nativeAnswer = (call) => jsonEncode({'result': 0});

      await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
      );

      final json = sentRequestJson();
      expect(json.containsKey('clientInfo'), isFalse);
      expect(json.containsKey('preferableReceiptType'), isFalse);
      expect(json.containsKey('originTransactionID'), isFalse);
      expect(json.containsKey('cancelMode'), isFalse);
      expect(json.containsKey('clientID'), isFalse);
    });

    test('V2-Antwort wird geparst (inkl. emvAppLabel in korrekter Schreibweise)', () async {
      nativeAnswer = (call) => jsonEncode({
            'result': 0,
            'transactionID': 'tx-1',
            'amount': 435,
            'tipAmount': 50,
            'totalAmount': 485,
            'approvedCode': '529625',
            'responseMessage': 'APPROVED',
            'transactionType': 1,
            'emvAppLabel': 'Visa Debit',
            'pinOk': true,
            'printByPaymentApp': true,
          });

      final result = await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 435,
        transactionMethode: TransactionMethode.card,
      );

      expect(result.result, 0);
      expect(result.transactionId, 'tx-1');
      expect(result.amountCents, 435);
      expect(result.tipAmountCents, 50);
      expect(result.totalAmountCents, 485);
      expect(result.approvedCode, '529625');
      expect(result.emvAppLable, 'Visa Debit');
      expect(result.pinOk, isTrue);
    });
  });

  group('registerTransactionV2-Wire-Format', () {
    test('sendet registerJson mit clientID', () async {
      nativeAnswer = (call) => jsonEncode({
            'resultCode': 0,
            'transactionId': 'd03484bc-509e-11ee-ba37-77691fde9486',
          });

      final result =
          await GptomAidlPlugin().registerTransactionV2Android(clientId: 'client-1');

      final call = nativeCalls.singleWhere((c) => c.method == 'registerTransactionV2');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect(jsonDecode(args['registerJson'] as String), {'clientID': 'client-1'});
      // Achtung: im Register-Result heißt der Key transactionId (kleines d).
      expect(result.transactionId, 'd03484bc-509e-11ee-ba37-77691fde9486');
      expect(result.resultCode, 0);
    });
  });

  group('inquireTransaction-Wire-Format', () {
    test('parst die Antwort mit den echten Backend-Keys (inkl. Tippfehlern)', () async {
      // Feldnamen exakt wie InquireResultEntity der AIDL-Bibliothek:
      // trasanctionID und transacitonType sind Backend-Tippfehler,
      // die Beträge kommen als Cent-Strings.
      nativeAnswer = (call) => jsonEncode({
            'result': 0,
            'trasanctionID': 'tx-1',
            'transacitonType': 1,
            'amount': '1111',
            'tipAmount': '50',
            'totalAmount': '1161',
            'emvAppLable': 'Visa Debit',
            'cardNumber': '479608******1859',
            'responseMessage': 'APPROVED',
            'pinOk': false,
          });

      final result = await GptomAidlPlugin().inquireTransactionAndroid('tx-1');

      final call = nativeCalls.singleWhere((c) => c.method == 'inquireTransaction');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect(args['transactionId'], 'tx-1');

      expect(result.result, 0);
      expect(result.transactionId, 'tx-1');
      expect(result.amountCents, 1111);
      expect(result.tipAmountCents, 50);
      expect(result.totalAmountCents, 1161);
      expect(result.emvAppLable, 'Visa Debit');
      expect(result.cardNumber, '479608******1859');
    });
  });

  group('gpTomLogin-Wire-Format', () {
    test('sendet die LoginEntity-Feldnamen', () async {
      nativeAnswer = (call) => true;

      await GptomAidlPlugin().loginGpTom(
        username: 'user@example.com',
        password: 'geheim',
        terminalId: '11263520',
      );

      final call = nativeCalls.singleWhere((c) => c.method == 'gpTomLogin');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect(args, {
        'username': 'user@example.com',
        'password': 'geheim',
        'terminalId': '11263520',
        'authCode': null,
      });
    });
  });
}
