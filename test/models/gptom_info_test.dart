import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/models/gptom_info.dart';
import 'package:gptom_aidl_plugin/models/gptom_login.dart';

void main() {
  group('GpTomInfo.fromMap', () {
    test('UNVERIFIED_LOGGED_IN wird erkannt', () {
      final i = GpTomInfo.fromMap(
          {'logInStatus': 'UNVERIFIED_LOGGED_IN', 'isLoggedIn': true});
      expect(i.loginState, GptomLoginState.unverifiedLoggedIn);
    });

    test('ohne logInStatus entscheidet isLoggedIn', () {
      expect(GpTomInfo.fromMap({'isLoggedIn': true}).loginState,
          GptomLoginState.loggedIn);
      expect(GpTomInfo.fromMap({'isLoggedIn': false}).loginState,
          GptomLoginState.loggedOut);
      expect(GpTomInfo.fromMap({}).loginState, GptomLoginState.unknown);
    });

    test('merchantLocation als Text', () {
      final i = GpTomInfo.fromMap({'merchantLocation': 'city=Wien'});
      expect(i.merchantLocationText, 'city=Wien');
      expect(GpTomInfo.fromMap({'merchantLocation': 5}).merchantLocationText,
          isNull);
    });

    test('Standard ist unknown', () {
      expect(GpTomInfo().loginState, GptomLoginState.unknown);
    });
  });

  group('GpTomInfo.fromIosAppStatus', () {
    test('mit vollem userInfo', () {
      final status = <String, dynamic>{
        'appVersion': '1.80.0',
        'userInfo': {
          'clientId': 'c-1',
          'email': 'livia@melisse-nails.example',
          'businessId': 'b-1',
          'vatId': 'ATU12345675',
          'tid': '12345678',
          'mid': 'm-1',
          'tipEnabled': true,
          'printerAvailable': false,
          'manualTransactionRestricted': true,
          'merchantLocation': {'city': 'Wien', 'zip': '1010'},
        },
      };
      final i = GpTomInfo.fromIosAppStatus(status);
      expect(i.appVersion, '1.80.0');
      expect(i.isLoggedIn, isTrue);
      expect(i.loginState, GptomLoginState.loggedIn);
      expect(i.tid, '12345678');
      expect(i.mid, 'm-1');
      expect(i.clientId, 'c-1');
      expect(i.businessId, 'b-1');
      expect(i.email, 'livia@melisse-nails.example');
      expect(i.vat, 'ATU12345675');
      expect(i.tipEnabled, isTrue);
      expect(i.printerAvailable, isFalse);
      expect(i.manualTransactionRestricted, isTrue);
      expect(i.merchantLocationEntity, {'city': 'Wien', 'zip': '1010'});
      expect(i.raw, status);
    });

    test('ohne userInfo abgemeldet', () {
      final i = GpTomInfo.fromIosAppStatus({'appVersion': '1.80.0'});
      expect(i.isLoggedIn, isFalse);
      expect(i.loginState, GptomLoginState.loggedOut);
      expect(i.tid, isNull);
    });

    test('unerwartete Typen: Zahlen als Text, Wahrheitswerte als Text', () {
      final i = GpTomInfo.fromIosAppStatus({
        'appVersion': 180,
        'userInfo': {
          'tid': 12345678,
          'mid': 987654321,
          'clientId': null,
          'tipEnabled': 'true',
          'printerAvailable': 'false',
          'manualTransactionRestricted': 'vielleicht',
          'merchantLocation': 'Wien',
        },
      });
      expect(i.loginState, GptomLoginState.loggedIn);
      expect(i.appVersion, '180');
      expect(i.tid, '12345678');
      expect(i.mid, '987654321');
      expect(i.clientId, isNull);
      expect(i.tipEnabled, isTrue);
      expect(i.printerAvailable, isFalse);
      expect(i.manualTransactionRestricted, isNull);
      expect(i.merchantLocationEntity, isNull);
    });
  });
}
