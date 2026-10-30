import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/preferable_receipt_type.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_method_channel.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_platform_interface.dart';
import 'package:gptom_aidl_plugin/gptom_security.dart';
import 'package:gptom_aidl_plugin/models/gptom_app_check.dart';

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
    MethodChannelGptomAidlPlugin.debugReleaseMode = null;
    GptomSecurityConfig.current = const GptomSecurityConfig();
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

  group('Wächter-Frist (Android)', () {
    test('timeout wird als Steuerfeld timeoutMs mitgeschickt', () async {
      nativeAnswer = (call) => jsonEncode({'result': 0});

      await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
        timeout: const Duration(seconds: 90),
      );

      expect(sentRequestJson()['timeoutMs'], 90000);
    });

    test('ohne Angabe bleibt der native Standard (kein timeoutMs im JSON)', () async {
      nativeAnswer = (call) => jsonEncode({'result': 0});

      await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
      );

      expect(sentRequestJson().containsKey('timeoutMs'), isFalse);
    });

    test('nativer TIMEOUT wird zu result -1003, nicht zu einer Ausnahme', () async {
      // So meldet der Android-Wächter, dass GP tom nicht geantwortet hat.
      nativeAnswer = (call) => throw PlatformException(
            code: 'TIMEOUT',
            message: 'GP tom hat nicht geantwortet',
          );

      final result = await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
      );

      // Gleicher Code wie auf iOS – die App braucht nur einen Weg.
      expect(result.result, GptomResultCode.timeout);
      expect(result.error?.errorCode, GptomErrorCode.timeout);
      expect(result.responseMessage, 'GP tom hat nicht geantwortet');
    });

    test('andere PlatformExceptions bleiben Ausnahmen', () async {
      nativeAnswer = (call) => throw PlatformException(code: 'NOT_BOUND');

      await expectLater(
        GptomAidlPlugin().sell(
          transactionIdAndroid: 'tx-1',
          amountCents: 100,
          transactionMethode: TransactionMethode.card,
        ),
        throwsA(isA<PlatformException>()),
      );
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

  group('Sicherheitsargumente, App-Prüfung und Timeouts', () {
    final pinKlein = List.filled(32, 'ab').join();
    final pinNormal = List.filled(32, 'AB').join(':');

    test('bindService schickt normalisierte Pins und verifySignature', () async {
      GptomSecurityConfig.current = GptomSecurityConfig(
        trustedSignaturesAndroid: [pinKlein],
        verifySignatureAndroid: false,
      );
      nativeAnswer = (call) => true;

      await GptomAidlPluginPlatform.instance.bindService();
      await GptomAidlPluginPlatform.instance.bindLoginService();
      await GptomAidlPluginPlatform.instance.bindInfoService();

      expect(nativeCalls.map((c) => c.method),
          ['bindService', 'bindLoginService', 'bindInfoService']);
      for (final c in nativeCalls) {
        final args = Map<String, dynamic>.from(c.arguments as Map);
        expect(args['trustedSignatures'], [pinNormal]);
        expect(args['verifySignature'], false);
        expect(args['isDev'], false);
      }
    });

    test('Dev-Paket im Release gesperrt', () async {
      MethodChannelGptomAidlPlugin.debugReleaseMode = true;
      nativeAnswer = (call) => true;

      final ergebnis =
          await GptomAidlPluginPlatform.instance.bindLoginService(isDevAndroid: true);

      expect(ergebnis, isFalse);
      expect(nativeCalls.where((c) => c.method == 'bindLoginService'), isEmpty);

      GptomSecurityConfig.current =
          const GptomSecurityConfig(allowDevPackageInRelease: true);
      final erlaubt =
          await GptomAidlPluginPlatform.instance.bindLoginService(isDevAndroid: true);
      expect(erlaubt, isTrue);
      expect(nativeCalls.where((c) => c.method == 'bindLoginService'), hasLength(1));
    });

    test('checkGpTomApp parst die native Map', () async {
      nativeAnswer = (call) => {
            'installed': true,
            'trusted': true,
            'source': 'pinned',
            'signatureSha256': [pinNormal],
            'versionName': '1.2.3',
            'versionCode': 42,
          };

      final check = await GptomAidlPluginPlatform.instance.checkGpTomApp();

      expect(check.installed, isTrue);
      expect(check.trusted, isTrue);
      expect(check.source, GptomTrustSource.pinned);
      expect(check.signatureSha256, [pinNormal]);
      expect(check.versionCode, 42);
      final args = Map<String, dynamic>.from(nativeCalls.single.arguments as Map);
      expect(nativeCalls.single.method, 'checkGpTomApp');
      expect(args['verifySignature'], true);
      expect(args['trustedSignatures'], <String>[]);
    });

    test('checkGpTomApp meldet Dev-Paket im Release als gesperrt', () async {
      MethodChannelGptomAidlPlugin.debugReleaseMode = true;
      nativeAnswer = (call) => call.method == 'existGpTomApp';

      final check =
          await GptomAidlPluginPlatform.instance.checkGpTomApp(isDevAndroid: true);

      expect(check.installed, isTrue);
      expect(check.trusted, isFalse);
      expect(check.source, GptomTrustSource.devPackageBlocked);
      expect(nativeCalls.map((c) => c.method), ['existGpTomApp']);
    });

    test('resetTrustedSignature ruft nativ auf', () async {
      nativeAnswer = (call) => true;
      expect(await GptomAidlPluginPlatform.instance.resetTrustedSignature(), isTrue);
      expect(nativeCalls.single.method, 'resetTrustedSignature');
    });

    test('getGpTomInfo schickt timeoutMs', () async {
      nativeAnswer = (call) => null;

      await GptomAidlPluginPlatform.instance
          .getGpTomInfo(timeout: const Duration(seconds: 7));
      await GptomAidlPluginPlatform.instance.getGpTomInfo();

      final erster = nativeCalls[0].arguments as Map;
      expect(erster['timeoutMs'], 7000);
      expect(nativeCalls[1].arguments, isNull);
    });

    test('register-TIMEOUT wird zu RegisterResult -1003', () async {
      nativeAnswer = (call) =>
          throw PlatformException(code: 'TIMEOUT', message: 'keine Antwort');

      final r = await GptomAidlPluginPlatform.instance
          .registerTransactionV2Android({'amount': 100});

      expect(r.resultCode, GptomResultCode.timeout);
      expect(r.resultCode, -1003);
    });
  });

  group('Referenz, Zahlungsart und Rückerstattung (Wire)', () {
    test('sell schickt originReferenceNum und paymentMethod', () async {
      nativeAnswer = (call) => jsonEncode({'result': 0});
      await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
        referenz: 'RE-2026-001',
        paymentMethod: GptomPaymentMethod.card,
      );
      final json = sentRequestJson();
      expect(json['originReferenceNum'], 'RE-2026-001');
      expect(json['paymentMethod'], 'CARD');
    });

    test('sell ohne referenz und paymentMethod lässt beide Keys weg', () async {
      nativeAnswer = (call) => jsonEncode({'result': 0});
      await GptomAidlPlugin().sell(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
      );
      final json = sentRequestJson();
      expect(json.containsKey('originReferenceNum'), isFalse);
      expect(json.containsKey('paymentMethod'), isFalse);
    });

    test('register schickt paymentMethod', () async {
      nativeAnswer = (call) => jsonEncode({'resultCode': 0, 'transactionId': 't'});
      await GptomAidlPlugin()
          .registerTransactionV2Android(paymentMethod: GptomPaymentMethod.cash);
      final call = nativeCalls.singleWhere((c) => c.method == 'registerTransactionV2');
      final args = Map<String, dynamic>.from(call.arguments as Map);
      expect(jsonDecode(args['registerJson'] as String)['paymentMethod'], 'CASH');
    });

    test('refund ohne originTransactionId lässt den Key weg', () async {
      nativeAnswer = (call) => jsonEncode({'result': 0});
      await GptomAidlPlugin().refund(
        transactionIdAndroid: 'tx-1',
        amountCents: 100,
        referenz: 'RE-1',
      );
      final json = sentRequestJson();
      expect(json.containsKey('originTransactionID'), isFalse);
      expect(json['transactionType'], 3);
      expect(json['originReferenceNum'], 'RE-1');
    });
  });
}
