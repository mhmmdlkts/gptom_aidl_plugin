import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/preferable_receipt_type.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/models/login_status.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';
import 'package:gptom_aidl_plugin/testing.dart';

/// Zeigt (und testet), wie konsumierende Apps mit dem
/// [FakeGptomAidlPluginPlatform] prüfen können, ob ihre Beleg- und
/// Transaktionsdaten korrekt beim Plugin ankommen.
void main() {
  late FakeGptomAidlPluginPlatform fake;
  late GptomAidlPlugin plugin;

  setUp(() {
    fake = FakeGptomAidlPluginPlatform();
    GptomAidlPluginPlatform.instance = fake;
    plugin = GptomAidlPlugin();
  });

  tearDown(() => fake.dispose());

  test('zeichnet Beleg-Daten eines Verkaufs auf', () async {
    fake.requestResult = RequestResult(result: 0, approvedCode: '529625');

    final result = await plugin.sell(
      transactionIdAndroid: 'tx-1',
      amountCents: 1250,
      transactionMethode: TransactionMethode.card,
      preferableReceiptType: PreferableReceiptType.email,
      clientInfo: {'email': 'kunde@example.com'},
    );

    expect(result.approvedCode, '529625');

    final params = fake.requestCalls.single;
    expect(params['amount'], 1250);
    expect(params['preferableReceiptType'], 'EMAIL');
    expect(params['clientInfo'], {
      'contact': {'email': 'kunde@example.com'},
    });
  });

  test('zeichnet Register-, State- und Inquire-Aufrufe auf', () async {
    await plugin.registerTransactionV2Android(clientId: 'client-1');
    await plugin.stateRequestAndroid('fake-tx');
    await plugin.inquireTransactionAndroid('fake-tx');

    expect(fake.registerCalls.single, {'clientID': 'client-1'});
    expect(fake.stateRequests, ['fake-tx']);
    expect(fake.inquireRequests, ['fake-tx']);
  });

  test('Login-Status-Pushes lassen sich simulieren', () async {
    final eventFuture = plugin.loginStatusStream.first;

    fake.emitLoginStatus(GpTomLoginEvent(
      status: GpTomLoginStatus.userLoggedIn,
      rawStatus: 'USER_LOGGED_IN',
    ));

    final event = await eventFuture;
    expect(event.isLoggedIn, isTrue);
  });

  test('Antworten sind konfigurierbar', () async {
    fake.bindServiceResult = false;
    expect(await plugin.bindService(), isFalse);
    expect(fake.bindServiceCalls, 1);
  });

  test('onLogin-Ereignis kommt im loginStatusStream an', () async {
    fake.onLogin = (call) => GpTomLoginEvent(
          status: GpTomLoginStatus.userLoggedIn,
          rawStatus: 'USER_LOGGED_IN',
        );
    final eventFuture = plugin.loginStatusStream.first;

    await GptomAidlPluginPlatform.instance.loginGpTom(
      username: 'livia@melisse-nails.example',
      password: 'pw',
      terminalId: '12345678',
    );

    expect((await eventFuture).isLoggedIn, isTrue);
    expect(fake.loginCalls.single['terminalId'], '12345678');
  });

  test('onLogout und onChangePassword liefern Ereignisse', () async {
    fake.onLogout = () => GpTomLoginEvent(
        status: GpTomLoginStatus.userLoggedOut, rawStatus: 'USER_LOGGED_OUT');
    final f = plugin.loginStatusStream.first;
    await GptomAidlPluginPlatform.instance.logoutGpTom();
    expect((await f).status, GpTomLoginStatus.userLoggedOut);
  });

  test('getGpTomInfoError wird geworfen, Timeout wird aufgezeichnet', () async {
    fake.getGpTomInfoError = StateError('kaputt');
    await expectLater(
      GptomAidlPluginPlatform.instance
          .getGpTomInfo(timeout: const Duration(seconds: 3)),
      throwsStateError,
    );
    expect(fake.getGpTomInfoTimeouts, [const Duration(seconds: 3)]);
    expect(fake.getGpTomInfoCalls, 1);
  });

  test('checkGpTomApp und resetTrustedSignature werden gezählt', () async {
    final check = await GptomAidlPluginPlatform.instance.checkGpTomApp();
    await GptomAidlPluginPlatform.instance.resetTrustedSignature();
    expect(check.trusted, isTrue);
    expect(check.source, GptomTrustSource.pinned);
    expect(fake.checkGpTomAppCalls, 1);
    expect(fake.resetTrustedSignatureCalls, 1);
  });

  test('openApp wird gezählt und liefert openAppResult', () async {
    expect(await GptomAidlPluginPlatform.instance.openApp(), isTrue);
    fake.openAppResult = false;
    expect(await GptomAidlPluginPlatform.instance.openApp(isDevAndroid: true),
        isFalse);
    expect(fake.openAppCalls, [false, true]);
  });
}
