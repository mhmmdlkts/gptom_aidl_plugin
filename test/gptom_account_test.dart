import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/gptom_account.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';
import 'package:gptom_aidl_plugin/models/login_status.dart';
import 'package:gptom_aidl_plugin/testing.dart';

/// Fake mit eigenem Login-Strom, damit sich prüfen lässt, wann jemand
/// zuhört.
class _HorchFake extends FakeGptomAidlPluginPlatform {
  final steuerung = StreamController<GpTomLoginEvent>.broadcast();

  @override
  Stream<GpTomLoginEvent> get loginStatusStream => steuerung.stream;
}

/// Fake, dessen nativer Login-Aufruf scheitert.
class _KaputtFake extends FakeGptomAidlPluginPlatform {
  @override
  Future<bool> loginGpTom({
    required String username,
    required String password,
    required String terminalId,
    String? authCode,
  }) async {
    throw PlatformException(code: 'LOGIN_ERROR', message: 'kaputt $password');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const benutzer = 'livia@melisse-nails.example';
  const passwort = 'Geheim 1+2&3%#ä';
  const zugang = GptomCredentials(
    username: benutzer,
    password: passwort,
    terminalId: '12345678',
  );
  const kurz = Duration(milliseconds: 50);

  late FakeGptomAidlPluginPlatform fake;
  late GptomAccount konto;

  GpTomLoginEvent ereignis(String status, [String? message]) => GpTomLoginEvent(
        status: GpTomLoginStatus.fromKey(status),
        rawStatus: status,
        message: message,
      );

  GpTomInfo status(GptomLoginState zustand, {String? tid}) => GpTomInfo(
        loginState: zustand,
        isLoggedIn: zustand == GptomLoginState.loggedIn,
        tid: tid,
      );

  setUp(() {
    GptomAccount.debugReset();
    GptomAidlPluginIOS.debugReset();
    GptomSecurityConfig.current = const GptomSecurityConfig();
    fake = FakeGptomAidlPluginPlatform();
    konto = GptomAccount(platform: fake, isIOS: false);
  });

  tearDown(() async {
    GptomAccount.debugReset();
    GptomAidlPluginIOS.debugReset();
    GptomSecurityConfig.current = const GptomSecurityConfig();
    await fake.dispose();
  });

  group('Android: login, logout, changePassword', () {
    test('login wartet auf USER_LOGGED_IN und ignoriert USER_LOGGED_OUT davor',
        () async {
      fake.onLogin = (_) {
        fake.emitLoginStatus(ereignis('USER_LOGGED_OUT'));
        return ereignis('USER_LOGGED_IN', 'angemeldet');
      };
      final r = await konto.login(
        const GptomCredentials(
          username: ' $benutzer ',
          password: passwort,
          terminalId: ' 12345678 ',
        ),
        timeout: kurz,
      );
      expect(r.outcome, GptomLoginOutcome.loggedIn);
      expect(r.rawStatus, 'USER_LOGGED_IN');
      expect(r.message, 'angemeldet');
      expect(fake.bindLoginServiceCalls, 1);
      final aufruf = fake.loginCalls.single;
      expect(aufruf['username'], benutzer);
      expect(aufruf['password'], passwort);
      expect(aufruf['terminalId'], '12345678');
      expect(aufruf['authCode'], isNull);
    });

    test('TID_RELEASE_REQUEST → tidReleaseRequired, needsCode', () async {
      fake.onLogin = (aufruf) => aufruf['authCode'] == null
          ? ereignis('TID_RELEASE_REQUEST')
          : ereignis('TID_ASSIGNED_AND_LOGGED_IN');
      final erst = await konto.login(zugang, timeout: kurz);
      expect(erst.outcome, GptomLoginOutcome.tidReleaseRequired);
      expect(erst.needsCode, isTrue);

      final dann = await konto.login(zugang, authCode: '482193', timeout: kurz);
      expect(fake.loginCalls.last['authCode'], '482193');
      expect(dann.outcome, GptomLoginOutcome.loggedIn);
      expect(dann.toString(), isNot(contains('482193')));
    });

    test('zweiter Login während des ersten → busy', () async {
      fake.onLogin = (_) => null;
      final erster = konto.login(zugang, timeout: kurz);
      final andere = GptomAccount(platform: fake, isIOS: false);
      expect((await andere.login(zugang, timeout: kurz)).outcome,
          GptomLoginOutcome.busy);
      expect((await andere.logout(timeout: kurz)).outcome,
          GptomLoginOutcome.busy);
      expect(
          (await andere.changePassword(
            username: benutzer,
            currentPassword: passwort,
            newPassword: 'neu',
            terminalId: '12345678',
            timeout: kurz,
          ))
              .outcome,
          GptomLoginOutcome.busy);
      expect(
          (await andere.ensureLoggedIn(
                  credentials: () => zugang, timeout: kurz))
              .outcome,
          GptomLoginOutcome.busy);
      expect((await erster).outcome, GptomLoginOutcome.timeout);
      expect(fake.loginCalls, hasLength(1));
      expect(fake.logoutCalls, 0);
      expect(fake.changePasswordCalls, isEmpty);

      // Danach ist die Sperre wieder frei.
      fake.onLogin = (_) => ereignis('USER_LOGGED_IN');
      expect((await konto.login(zugang, timeout: kurz)).outcome,
          GptomLoginOutcome.loggedIn);
    });

    test('kein Ereignis → timeout', () async {
      final horch = _HorchFake();
      bool? hoerteBeimAufruf;
      horch.onLogin = (_) {
        hoerteBeimAufruf = horch.steuerung.hasListener;
        return null;
      };
      final r = await GptomAccount(platform: horch, isIOS: false)
          .login(zugang, timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.timeout);
      // Vor dem nativen Aufruf abonniert, danach wieder abgemeldet.
      expect(hoerteBeimAufruf, isTrue);
      expect(horch.steuerung.hasListener, isFalse);
      await horch.steuerung.close();
      await horch.dispose();
    });

    test('bindLoginService false → notSupported', () async {
      fake.bindLoginServiceResult = false;
      final r = await konto.login(zugang, timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.notSupported);
      expect(fake.loginCalls, isEmpty);
    });

    test('nicht vertrauenswürdig → untrustedApp und loginCalls bleibt leer',
        () async {
      fake.appCheck = const GptomAppCheck(
        installed: true,
        trusted: false,
        source: GptomTrustSource.mismatch,
      );
      final r = await konto.login(zugang, timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.untrustedApp);
      expect(fake.loginCalls, isEmpty);
      expect(fake.bindLoginServiceCalls, 0);
    });

    test('nicht installiert → notInstalled ohne Bindung', () async {
      fake.appCheck = const GptomAppCheck(
        installed: false,
        trusted: false,
        source: GptomTrustSource.notInstalled,
      );
      final r = await konto.logout(timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.notInstalled);
      expect(fake.logoutCalls, 0);
      expect(fake.bindLoginServiceCalls, 0);
    });

    test('PlatformException beim Aufruf → failed mit fester Meldung', () async {
      final kaputt = _KaputtFake();
      final r = await GptomAccount(platform: kaputt, isIOS: false)
          .login(zugang, timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.failed);
      expect(r.message, isNotNull);
      expect(r.message, isNot(contains('Geheim')));
      expect(r.toString(), isNot(contains('Geheim')));
      await kaputt.dispose();
    });

    test('Aufruf nicht angenommen (false) → failed', () async {
      fake.logoutResult = false;
      final r = await konto.logout(timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.failed);
    });

    test('logout → loggedOut', () async {
      fake.onLogout = () {
        fake.emitLoginStatus(ereignis('USER_LOGGED_IN'));
        return ereignis('USER_LOGGED_OUT');
      };
      final r = await konto.logout(timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.loggedOut);
      expect(r.rawStatus, 'USER_LOGGED_OUT');
      expect(fake.logoutCalls, 1);
    });

    test('changePassword Schritt 1 und 2 → validationOnly/authCode wie Spec',
        () async {
      fake.onChangePassword = (aufruf) => aufruf['authCode'] == null
          ? ereignis('PASSWORD_PENDING_CONFIRMATION')
          : ereignis('PASSWORD_CHANGED');

      final eins = await konto.changePassword(
        username: benutzer,
        currentPassword: passwort,
        newPassword: 'Neu 4+5&6',
        terminalId: '12345678',
        timeout: kurz,
      );
      expect(eins.outcome, GptomLoginOutcome.passwordPendingConfirmation);
      expect(eins.needsCode, isTrue);
      expect(fake.changePasswordCalls.first, {
        'currentPassword': passwort,
        'newPassword': 'Neu 4+5&6',
        'authCode': null,
        'validationOnly': true,
      });

      final zwei = await konto.changePassword(
        username: benutzer,
        currentPassword: passwort,
        newPassword: 'Neu 4+5&6',
        terminalId: '12345678',
        code: '482193',
        timeout: kurz,
      );
      expect(zwei.outcome, GptomLoginOutcome.passwordChanged);
      expect(fake.changePasswordCalls.last, {
        'currentPassword': passwort,
        'newPassword': 'Neu 4+5&6',
        'authCode': '482193',
        'validationOnly': false,
      });
    });
  });

  group('Android: getStatus', () {
    test('liefert die Info mit Standard-Wächter 20 s', () async {
      fake.gpTomInfo = status(GptomLoginState.loggedIn, tid: '12345678');
      final info = await konto.getStatus();
      expect(info!.tid, '12345678');
      expect(fake.bindInfoServiceCalls, 1);
      expect(fake.getGpTomInfoTimeouts.single, const Duration(seconds: 20));
    });

    test('eigener timeout geht an den Wächter', () async {
      fake.gpTomInfo = status(GptomLoginState.loggedOut);
      await konto.getStatus(timeout: kurz);
      expect(fake.getGpTomInfoTimeouts.single, kurz);
    });

    test('bindInfoService false → null', () async {
      fake.bindInfoServiceResult = false;
      fake.gpTomInfo = status(GptomLoginState.loggedIn);
      expect(await konto.getStatus(), isNull);
      expect(fake.getGpTomInfoCalls, 0);
    });

    test('PlatformException → null', () async {
      fake.getGpTomInfoError = PlatformException(code: 'TIMEOUT');
      expect(await konto.getStatus(), isNull);
    });
  });

  group('ensureLoggedIn', () {
    var abgefragt = 0;
    FutureOr<GptomCredentials?> Function() liefert(GptomCredentials? c) => () {
          abgefragt++;
          return c;
        };

    setUp(() => abgefragt = 0);

    test('nicht installiert → notInstalled', () async {
      fake.appCheck = const GptomAppCheck(
        installed: false,
        trusted: false,
        source: GptomTrustSource.notInstalled,
      );
      final r = await konto.ensureLoggedIn(credentials: liefert(zugang));
      expect(r.outcome, GptomLoginOutcome.notInstalled);
      expect(abgefragt, 0);
      expect(fake.getGpTomInfoCalls, 0);
      expect(fake.loginCalls, isEmpty);
    });

    test('nicht vertrauenswürdig → untrustedApp', () async {
      fake.appCheck = const GptomAppCheck(
        installed: true,
        trusted: false,
        source: GptomTrustSource.mismatch,
      );
      final r = await konto.ensureLoggedIn(credentials: liefert(zugang));
      expect(r.outcome, GptomLoginOutcome.untrustedApp);
      expect(abgefragt, 0);
      expect(fake.getGpTomInfoCalls, 0);
      expect(fake.loginCalls, isEmpty);
    });

    test('angemeldet mit gleicher TID → alreadyLoggedIn, credentials nie gerufen',
        () async {
      final info = status(GptomLoginState.loggedIn, tid: '12345678');
      fake.gpTomInfo = info;
      final r = await konto.ensureLoggedIn(
        credentials: liefert(zugang),
        expectedTerminalId: '12345678',
      );
      expect(r.outcome, GptomLoginOutcome.alreadyLoggedIn);
      expect(r.isLoggedIn, isTrue);
      expect(r.info, same(info));
      expect(abgefragt, 0);
      expect(fake.loginCalls, isEmpty);
    });

    test('expectedTerminalId mit Leerzeichen wird getrimmt verglichen', () async {
      fake.gpTomInfo = status(GptomLoginState.loggedIn, tid: '12345678');
      final r = await konto.ensureLoggedIn(
        credentials: liefert(zugang),
        expectedTerminalId: ' 12345678 ',
      );
      expect(r.outcome, GptomLoginOutcome.alreadyLoggedIn);
    });

    test('ohne expectedTerminalId oder ohne tid → alreadyLoggedIn', () async {
      fake.gpTomInfo = status(GptomLoginState.loggedIn, tid: '12345678');
      expect((await konto.ensureLoggedIn(credentials: liefert(zugang))).outcome,
          GptomLoginOutcome.alreadyLoggedIn);
      fake.gpTomInfo = status(GptomLoginState.loggedIn);
      expect(
          (await konto.ensureLoggedIn(
            credentials: liefert(zugang),
            expectedTerminalId: '12345678',
          ))
              .outcome,
          GptomLoginOutcome.alreadyLoggedIn);
      expect(abgefragt, 0);
    });

    test('andere TID → otherTerminal ohne Umschalten', () async {
      fake.gpTomInfo = status(GptomLoginState.loggedIn, tid: '87654321');
      final r = await konto.ensureLoggedIn(
        credentials: liefert(zugang),
        expectedTerminalId: '12345678',
      );
      expect(r.outcome, GptomLoginOutcome.otherTerminal);
      expect(r.info!.tid, '87654321');
      expect(abgefragt, 0);
      expect(fake.loginCalls, isEmpty);
      expect(fake.logoutCalls, 0);
    });

    test('unverifiedLoggedIn → offline, kein Login', () async {
      fake.gpTomInfo = status(GptomLoginState.unverifiedLoggedIn);
      final r = await konto.ensureLoggedIn(credentials: liefert(zugang));
      expect(r.outcome, GptomLoginOutcome.offline);
      expect(abgefragt, 0);
      expect(fake.loginCalls, isEmpty);
      expect(fake.bindLoginServiceCalls, 0);
    });

    test('abgemeldet, credentials liefert null → noCredentials', () async {
      fake.gpTomInfo = status(GptomLoginState.loggedOut);
      final r = await konto.ensureLoggedIn(credentials: liefert(null));
      expect(r.outcome, GptomLoginOutcome.noCredentials);
      expect(r.info!.loginState, GptomLoginState.loggedOut);
      expect(abgefragt, 1);
      expect(fake.loginCalls, isEmpty);
    });

    test('abgemeldet mit Zugangsdaten → loggedIn mit info', () async {
      final info = status(GptomLoginState.loggedOut);
      fake.gpTomInfo = info;
      fake.onLogin = (_) => ereignis('USER_LOGGED_IN');
      final r = await konto.ensureLoggedIn(
        credentials: () async {
          abgefragt++;
          return zugang;
        },
        expectedTerminalId: '12345678',
        timeout: kurz,
      );
      expect(r.outcome, GptomLoginOutcome.loggedIn);
      expect(r.rawStatus, 'USER_LOGGED_IN');
      expect(r.info, same(info));
      expect(abgefragt, 1);
      expect(fake.loginCalls.single['password'], passwort);
      expect(fake.getGpTomInfoTimeouts.single, kurz);
    });

    test('Zustand unbekannt → Login wie abgemeldet', () async {
      fake.gpTomInfo = status(GptomLoginState.unknown);
      fake.onLogin = (_) => ereignis('TID_RELEASE_REQUEST');
      final r = await konto.ensureLoggedIn(
          credentials: liefert(zugang), timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.tidReleaseRequired);
      expect(r.needsCode, isTrue);
      expect(abgefragt, 1);
    });

    test('Status-Wächter TIMEOUT → timeout', () async {
      fake.getGpTomInfoError = PlatformException(code: 'TIMEOUT');
      final r = await konto.ensureLoggedIn(credentials: liefert(zugang));
      expect(r.outcome, GptomLoginOutcome.timeout);
      expect(abgefragt, 0);
      expect(fake.loginCalls, isEmpty);
    });

    test('Info-Service fehlt → notSupported, anderer Fehler → failed', () async {
      fake.bindInfoServiceResult = false;
      expect((await konto.ensureLoggedIn(credentials: liefert(zugang))).outcome,
          GptomLoginOutcome.notSupported);
      fake.bindInfoServiceResult = true;
      fake.getGpTomInfoError = PlatformException(code: 'NOT_BOUND');
      expect((await konto.ensureLoggedIn(credentials: liefert(zugang))).outcome,
          GptomLoginOutcome.failed);
      fake.getGpTomInfoError = null;
      fake.gpTomInfo = null;
      expect((await konto.ensureLoggedIn(credentials: liefert(zugang))).outcome,
          GptomLoginOutcome.failed);
      expect(abgefragt, 0);
    });

    test('Exception aus credentials wird weitergereicht, Sperre wieder frei',
        () async {
      fake.gpTomInfo = status(GptomLoginState.loggedOut);
      await expectLater(
        konto.ensureLoggedIn(
            credentials: () => throw StateError('Speicher gesperrt')),
        throwsStateError,
      );
      fake.onLogin = (_) => ereignis('USER_LOGGED_IN');
      expect((await konto.login(zugang, timeout: kurz)).outcome,
          GptomLoginOutcome.loggedIn);
    });

    test('während ensureLoggedIn läuft → busy', () async {
      fake.gpTomInfo = status(GptomLoginState.loggedOut);
      fake.onLogin = (_) => ereignis('USER_LOGGED_IN');
      final freigabe = Completer<GptomCredentials?>();
      final laufend = konto.ensureLoggedIn(
          credentials: () => freigabe.future, timeout: kurz);
      await pumpEventQueue();
      expect((await konto.login(zugang, timeout: kurz)).outcome,
          GptomLoginOutcome.busy);
      freigabe.complete(zugang);
      expect((await laufend).outcome, GptomLoginOutcome.loggedIn);
      expect(fake.loginCalls, hasLength(1));
    });
  });

  group('iOS', () {
    final geoeffnet = <Uri>[];

    setUp(() {
      geoeffnet.clear();
      GptomAidlPluginIOS.debugSetRedirectScheme('meineapp');
      fake.appCheck = const GptomAppCheck(
        installed: true,
        trusted: true,
        source: GptomTrustSource.notApplicable,
      );
    });

    /// GP tom antwortet auf die Token-URL der Anfrage.
    void gpTom(Map<String, String> Function(Uri anfrage) antwort) {
      GptomAidlPluginIOS.debugLauncher = (uri) async {
        geoeffnet.add(uri);
        final redirect = Uri.parse(uri.queryParameters['redirectUrl']!)
            .replace(queryParameters: antwort(uri));
        scheduleMicrotask(() => GptomAidlPluginIOS.debugHandleRedirect(redirect));
        return true;
      };
    }

    test('iOS: ensureLoggedIn Status abgemeldet, dann Login COMPLETED → loggedIn',
        () async {
      gpTom((anfrage) => {
            'status': 'COMPLETED',
            if (anfrage.host == 'status') 'appStatus': '{"appVersion":"1.0"}',
          });
      final ios = GptomAccount(platform: fake, isIOS: true);
      final r = await ios.ensureLoggedIn(
        credentials: () => zugang,
        expectedTerminalId: '12345678',
        timeout: kurz,
      );
      expect(r.outcome, GptomLoginOutcome.loggedIn);
      expect(r.info!.loginState, GptomLoginState.loggedOut);
      expect(geoeffnet.map((u) => u.host), ['status', 'login']);
      expect(geoeffnet.last.queryParameters['password'], passwort);
      expect(fake.loginCalls, isEmpty);
      expect(fake.bindInfoServiceCalls, 0);
      expect(fake.bindLoginServiceCalls, 0);
    });

    test('iOS: ensureLoggedIn bereits angemeldet → alreadyLoggedIn', () async {
      gpTom((_) => {
            'status': 'COMPLETED',
            'appStatus': '{"userInfo":{"tid":"12345678"}}',
          });
      final r = await GptomAccount(platform: fake, isIOS: true).ensureLoggedIn(
        credentials: () => throw StateError('darf nicht gerufen werden'),
        expectedTerminalId: ' 12345678 ',
        timeout: kurz,
      );
      expect(r.outcome, GptomLoginOutcome.alreadyLoggedIn);
      expect(geoeffnet.map((u) => u.host), ['status']);
    });

    test('iOS: login mit authCode → invalidArgument, GP tom nicht geöffnet',
        () async {
      gpTom((_) => {'status': 'COMPLETED'});
      final r = await GptomAccount(platform: fake, isIOS: true)
          .login(zugang, authCode: '482193', timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.invalidArgument);
      expect(geoeffnet, isEmpty);
      expect(r.toString(), isNot(contains('482193')));
    });

    test('iOS: logout, changePassword und getStatus über gptom://', () async {
      gpTom((anfrage) => {
            'status': 'COMPLETED',
            if (anfrage.host == 'status')
              'appStatus': '{"userInfo":{"tid":"12345678"}}',
          });
      final ios = GptomAccount(platform: fake, isIOS: true);
      expect((await ios.logout(timeout: kurz)).outcome,
          GptomLoginOutcome.loggedOut);
      final pw = await ios.changePassword(
        username: benutzer,
        currentPassword: passwort,
        newPassword: 'neu',
        terminalId: '12345678',
        code: '482193',
        timeout: kurz,
      );
      expect(pw.outcome, GptomLoginOutcome.passwordChanged);
      expect(geoeffnet.last.queryParameters['code'], '482193');
      final info = await ios.getStatus(timeout: kurz);
      expect(info!.tid, '12345678');
      expect(geoeffnet.map((u) => u.host),
          ['logout', 'change-password', 'status']);
      expect(fake.logoutCalls, 0);
      expect(fake.changePasswordCalls, isEmpty);
      expect(fake.getGpTomInfoCalls, 0);
    });

    test('iOS: Status ohne Antwort → ensureLoggedIn timeout', () async {
      GptomAidlPluginIOS.debugLauncher = (uri) async => true;
      final r = await GptomAccount(platform: fake, isIOS: true).ensureLoggedIn(
        credentials: () => zugang,
        timeout: kurz,
      );
      expect(r.outcome, GptomLoginOutcome.timeout);
    });
  });

  group('Fassade', () {
    setUp(() => GptomAidlPluginPlatform.instance = fake);

    test('security liest und setzt GptomSecurityConfig.current', () {
      const config = GptomSecurityConfig(redirectTokenIOS: false);
      GptomAidlPlugin.security = config;
      expect(GptomSecurityConfig.current, same(config));
      expect(GptomAidlPlugin.security, same(config));
    });

    test('security: ungültiger Pin wirft sofort, alte Konfiguration bleibt', () {
      const vorher = GptomSecurityConfig();
      GptomAidlPlugin.security = vorher;
      expect(
        () => GptomAidlPlugin.security =
            const GptomSecurityConfig(trustedSignaturesAndroid: ['kein-pin']),
        throwsArgumentError,
      );
      expect(GptomAidlPlugin.security, same(vorher));
    });

    test('resetTrustedSignatureAndroid und checkGpTomApp delegieren', () async {
      expect(await GptomAidlPlugin().resetTrustedSignatureAndroid(), isTrue);
      expect(fake.resetTrustedSignatureCalls, 1);
      final pruefung = await GptomAidlPlugin().checkGpTomApp();
      expect(pruefung.source, GptomTrustSource.pinned);
      expect(fake.checkGpTomAppCalls, 1);
    });

    test('login, logout, changePassword, getStatus und ensureLoggedIn delegieren',
        () async {
      final plugin = GptomAidlPlugin();
      fake.onLogin = (_) => ereignis('USER_LOGGED_IN');
      fake.onLogout = () => ereignis('USER_LOGGED_OUT');
      fake.onChangePassword = (_) => ereignis('PASSWORD_PENDING_CONFIRMATION');
      fake.gpTomInfo = status(GptomLoginState.loggedOut);

      expect((await plugin.login(zugang, timeout: kurz)).outcome,
          GptomLoginOutcome.loggedIn);
      expect((await plugin.logout(timeout: kurz)).outcome,
          GptomLoginOutcome.loggedOut);
      expect(
          (await plugin.changePassword(
            username: benutzer,
            currentPassword: passwort,
            newPassword: 'neu',
            terminalId: '12345678',
            timeout: kurz,
          ))
              .outcome,
          GptomLoginOutcome.passwordPendingConfirmation);
      expect((await plugin.getStatus(timeout: kurz))!.loginState,
          GptomLoginState.loggedOut);
      final r = await plugin.ensureLoggedIn(
          credentials: () => zugang, timeout: kurz);
      expect(r.outcome, GptomLoginOutcome.loggedIn);
      expect(fake.loginCalls, hasLength(2));
    });
  });
}
