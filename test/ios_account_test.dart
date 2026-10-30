import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';
import 'package:gptom_aidl_plugin/gptom_ios_account.dart';
import 'package:gptom_aidl_plugin/gptom_security.dart';
import 'package:gptom_aidl_plugin/models/gptom_login.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const benutzer = 'livia@melisse-nails.example';
  const passwort = 'Geheim 1+2&3%#ä';
  const zugang = GptomCredentials(
    username: benutzer,
    password: passwort,
    terminalId: '12345678',
  );

  Uri? gerufen;

  setUp(() {
    GptomSecurityConfig.current = const GptomSecurityConfig();
    GptomAidlPluginIOS.debugReset();
    GptomAidlPluginIOS.debugSetRedirectScheme('meineapp');
    gerufen = null;
  });

  tearDown(() {
    GptomAidlPluginIOS.debugReset();
    GptomSecurityConfig.current = const GptomSecurityConfig();
  });

  Uri antwortAuf(Uri anfrage, Map<String, String> query) =>
      Uri.parse(anfrage.queryParameters['redirectUrl']!)
          .replace(queryParameters: query);

  void gpTom({Uri Function(Uri anfrage)? antwort, bool oeffnenGelingt = true}) {
    GptomAidlPluginIOS.debugLauncher = (uri) async {
      gerufen = uri;
      if (antwort != null) {
        final redirect = antwort(uri);
        scheduleMicrotask(() => GptomAidlPluginIOS.debugHandleRedirect(redirect));
      }
      return oeffnenGelingt;
    };
  }

  group('URLs', () {
    test('Login-URL kodiert das Passwort ohne +', () {
      final uri = GptomIosAccount.buildLoginUri(
        username: benutzer,
        password: passwort,
        terminalId: '12345678',
        redirectUrl: 'meineapp://redirect/abc',
      );
      expect(uri.scheme, 'gptom');
      expect(uri.host, 'login');
      expect(uri.query, contains('password=Geheim%201%2B2%263%25%23%C3%A4'));
      expect(uri.query.replaceAll('%2B', ''), isNot(contains('+')));
      expect(uri.query, contains('tid=12345678'));
      expect(uri.query.indexOf('username='), lessThan(uri.query.indexOf('password=')));
      expect(uri.query.indexOf('password='), lessThan(uri.query.indexOf('tid=')));
      expect(uri.query.indexOf('tid='), lessThan(uri.query.indexOf('redirectUrl=')));
      expect(uri.queryParameters['password'], passwort);
    });

    test('Passwortwechsel Schritt 1 ohne code, Schritt 2 mit code', () {
      final eins = GptomIosAccount.buildChangePasswordUri(
        username: benutzer,
        password: 'alt',
        newPassword: 'neu',
        terminalId: '12345678',
        redirectUrl: 'meineapp://redirect/abc',
      );
      expect(eins.host, 'change-password');
      expect(eins.query, isNot(contains('code=')));
      final zwei = GptomIosAccount.buildChangePasswordUri(
        username: benutzer,
        password: 'alt',
        newPassword: 'neu',
        terminalId: '12345678',
        code: '123 456',
        redirectUrl: 'meineapp://redirect/abc',
      );
      expect(zwei.query, contains('code=123%20456'));
      expect(zwei.query.indexOf('tid='), lessThan(zwei.query.indexOf('code=')));
      expect(zwei.query.indexOf('code='), lessThan(zwei.query.indexOf('redirectUrl=')));
      final leer = GptomIosAccount.buildChangePasswordUri(
        username: benutzer,
        password: 'alt',
        newPassword: 'neu',
        terminalId: '12345678',
        code: '',
        redirectUrl: 'meineapp://redirect/abc',
      );
      expect(leer.query, isNot(contains('code=')));
    });

    test('Logout- und Status-URL', () {
      final aus = GptomIosAccount.buildLogoutUri(redirectUrl: 'meineapp://r/a');
      expect(aus.host, 'logout');
      expect(aus.queryParameters['redirectUrl'], 'meineapp://r/a');
      final st = GptomIosAccount.buildStatusUri(redirectUrl: 'meineapp://r/a');
      expect(st.host, 'status');
      expect(st.queryParameters['redirectUrl'], 'meineapp://r/a');
    });
  });

  group('Parser', () {
    GptomLoginResult parse(String q, GptomAccountOperation op,
            {bool code = false}) =>
        GptomIosAccount.loginResultFromRedirect(
            Uri.parse('meineapp://redirect?$q'), op,
            codeGesendet: code);

    test('COMPLETED, ERROR und CANCELLED', () {
      expect(parse('status=COMPLETED', GptomAccountOperation.login).outcome,
          GptomLoginOutcome.loggedIn);
      final fehler =
          parse('status=ERROR&error=tidAlreadyOccupied', GptomAccountOperation.login);
      expect(fehler.outcome, GptomLoginOutcome.tidOccupied);
      expect(fehler.rawStatus, 'ERROR');
      expect(fehler.rawError, 'tidAlreadyOccupied');
      expect(parse('status=CANCELLED', GptomAccountOperation.login).outcome,
          GptomLoginOutcome.cancelled);
    });

    test('Passwortwechsel mit und ohne Code', () {
      expect(
          parse('status=COMPLETED', GptomAccountOperation.changePassword,
                  code: true)
              .outcome,
          GptomLoginOutcome.passwordChanged);
      expect(
          parse('status=COMPLETED', GptomAccountOperation.changePassword)
              .outcome,
          GptomLoginOutcome.passwordPendingConfirmation);
    });

    test('Status: appStatus mit und ohne userInfo, kaputt', () {
      final mit = GptomIosAccount.infoFromStatusRedirect(Uri.parse(
          'meineapp://r?appStatus=${Uri.encodeComponent('{"appVersion":"1.0","userInfo":{"tid":"12345678"}}')}'));
      expect(mit!.loginState, GptomLoginState.loggedIn);
      expect(mit.tid, '12345678');
      final ohne = GptomIosAccount.infoFromStatusRedirect(Uri.parse(
          'meineapp://r?appStatus=${Uri.encodeComponent('{"appVersion":"1.0"}')}'));
      expect(ohne!.loginState, GptomLoginState.loggedOut);
      expect(
          GptomIosAccount.infoFromStatusRedirect(
              Uri.parse('meineapp://r?appStatus=kaputt')),
          isNull);
      expect(GptomIosAccount.infoFromStatusRedirect(Uri.parse('meineapp://r')),
          isNull);
    });
  });

  group('Abläufe', () {
    test('Login bei Antwort mit Token', () async {
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'COMPLETED'}));
      final r = await GptomIosAccount.login(zugang);
      expect(r.outcome, GptomLoginOutcome.loggedIn);
      expect(gerufen!.host, 'login');
    });

    test('Logout und Passwortwechsel', () async {
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'COMPLETED'}));
      expect((await GptomIosAccount.logout()).outcome,
          GptomLoginOutcome.loggedOut);
      final r = await GptomIosAccount.changePassword(
        username: benutzer,
        currentPassword: 'alt',
        newPassword: 'neu',
        terminalId: '12345678',
      );
      expect(r.outcome, GptomLoginOutcome.passwordPendingConfirmation);
      final r2 = await GptomIosAccount.changePassword(
        username: benutzer,
        currentPassword: 'alt',
        newPassword: 'neu',
        terminalId: '12345678',
        code: '123456',
      );
      expect(r2.outcome, GptomLoginOutcome.passwordChanged);
    });

    test('Launcher liefert false: cannotOpen', () async {
      gpTom(oeffnenGelingt: false);
      expect((await GptomIosAccount.login(zugang)).outcome,
          GptomLoginOutcome.cannotOpen);
    });

    test('Keine Antwort: timeout', () async {
      gpTom();
      final r = await GptomIosAccount.login(zugang,
          timeout: const Duration(milliseconds: 50));
      expect(r.outcome, GptomLoginOutcome.timeout);
    });

    test('Gefälschte Antwort ohne Token: timeout', () async {
      gpTom(
          antwort: (_) => Uri.parse('meineapp://redirect?status=COMPLETED'));
      final r = await GptomIosAccount.login(zugang,
          timeout: const Duration(milliseconds: 50));
      expect(r.outcome, GptomLoginOutcome.timeout);
    });

    test('Nicht aktiv: cannotOpen', () async {
      GptomAidlPluginIOS.debugLauncher = null;
      expect((await GptomIosAccount.login(zugang)).outcome,
          GptomLoginOutcome.cannotOpen);
      expect((await GptomIosAccount.logout()).outcome,
          GptomLoginOutcome.cannotOpen);
      expect((await GptomIosAccount.status()).fehler,
          GptomLoginOutcome.cannotOpen);
    });

    test('status liefert info', () async {
      gpTom(
          antwort: (a) => antwortAuf(a, {
                'status': 'COMPLETED',
                'appStatus': '{"userInfo":{"tid":"12345678"}}',
              }));
      final s = await GptomIosAccount.status();
      expect(s.fehler, isNull);
      expect(s.info!.loginState, GptomLoginState.loggedIn);
    });

    test('status ohne lesbaren appStatus: unknown; Abbruch: cancelled',
        () async {
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'COMPLETED'}));
      expect((await GptomIosAccount.status()).fehler, GptomLoginOutcome.unknown);
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'CANCELLED'}));
      expect(
          (await GptomIosAccount.status()).fehler, GptomLoginOutcome.cancelled);
    });

    test('status ERROR userNotLoggedIn: abgemeldet, kein Fehler', () async {
      gpTom(antwort: (a) =>
          antwortAuf(a, {'status': 'ERROR', 'error': 'userNotLoggedIn'}));
      final s = await GptomIosAccount.status();
      expect(s.fehler, isNull);
      expect(s.info!.loginState, GptomLoginState.loggedOut);
      expect(s.info!.isLoggedIn, isFalse);
    });

    test('status ERROR networkError: offline, sonst failed', () async {
      gpTom(antwort: (a) =>
          antwortAuf(a, {'status': 'ERROR', 'error': 'networkError'}));
      final offline = await GptomIosAccount.status();
      expect(offline.info, isNull);
      expect(offline.fehler, GptomLoginOutcome.offline);

      gpTom(antwort: (a) => antwortAuf(a, {'status': 'ERROR', 'error': 'failed'}));
      expect((await GptomIosAccount.status()).fehler, GptomLoginOutcome.failed);
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'ERROR'}));
      expect((await GptomIosAccount.status()).fehler, GptomLoginOutcome.failed);
    });

    test('status mit numerischer TID im appStatus', () async {
      gpTom(antwort: (a) => antwortAuf(a, {
            'status': 'COMPLETED',
            'appStatus': '{"userInfo":{"tid":12345678}}',
          }));
      final s = await GptomIosAccount.status();
      expect(s.fehler, isNull);
      expect(s.info!.tid, '12345678');
    });

    test('status ohne Antwort: timeout', () async {
      gpTom();
      final s = await GptomIosAccount.status(
          timeout: const Duration(milliseconds: 50));
      expect(s.fehler, GptomLoginOutcome.timeout);
    });

    test('Fehlertext enthält kein Passwort', () async {
      GptomAidlPluginIOS.debugLauncher = (uri) async {
        throw Exception('kaputt $uri');
      };
      final r = await GptomIosAccount.login(zugang);
      expect(r.outcome, GptomLoginOutcome.cannotOpen);
      expect(r.toString(), isNot(contains('Geheim')));
      expect(r.message, isNull);
    });
  });
}
