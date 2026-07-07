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
}
