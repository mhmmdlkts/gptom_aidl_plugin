import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'gptom_aidl_plugin_ios.dart';
import 'gptom_aidl_plugin_platform_interface.dart';
import 'gptom_ios_account.dart';
import 'gptom_result_code.dart';
import 'models/gptom_app_check.dart';
import 'models/gptom_info.dart';
import 'models/gptom_login.dart';

/// Status, Login, Logout und Passwortwechsel von GP tom auf Android und iOS,
/// zum Abwarten: Jede Operation liefert ein [GptomLoginResult] mit klarem
/// Ausgang, statt „abgeschickt, Ergebnis irgendwann im Stream“.
///
/// - **Android:** Login- und Info-Service (AIDL). Vor jeder Konto-Operation
///   wird die GP tom App geprüft ([checkGpTomApp]); ist sie nicht installiert
///   oder nicht vertrauenswürdig, gehen keine Zugangsdaten hinaus. Das
///   Ergebnis kommt als Login-Status-Ereignis und wird hier abgewartet.
/// - **iOS:** über `gptom://` und den Redirect ([GptomIosAccount]).
///
/// Es läuft immer nur eine Konto-Operation zur Zeit, über alle Instanzen
/// hinweg. Ein weiterer Aufruf von [login], [logout], [changePassword] oder
/// [ensureLoggedIn] liefert solange [GptomLoginOutcome.busy].
class GptomAccount {
  /// [platform] und [isIOS] sind für Tests. Standard: die registrierte
  /// Plattform-Implementierung bzw. ob der iOS-Weg aktiv ist.
  GptomAccount({GptomAidlPluginPlatform? platform, bool? isIOS})
      : _platform = platform,
        _isIOS = isIOS;

  final GptomAidlPluginPlatform? _platform;
  final bool? _isIOS;

  GptomAidlPluginPlatform get _plattform =>
      _platform ?? GptomAidlPluginPlatform.instance;

  bool get _ios => _isIOS ?? GptomAidlPluginIOS.isActive;

  /// Standard-Wartezeit für Login, Logout und Passwortwechsel (Android).
  static const Duration defaultAccountTimeout = Duration(seconds: 60);

  /// Standard-Frist des nativen Wächters für die Statusabfrage (Android).
  static const Duration defaultStatusTimeoutAndroid = Duration(seconds: 20);

  /// Marke der laufenden Operation; `null` = frei. Eine Marke statt eines
  /// Flags, damit eine alte Operation nach [debugReset] nicht die Sperre
  /// einer neueren freigibt.
  static Object? _laufend;

  /// Nur für Tests: gibt die Sperre frei.
  @visibleForTesting
  static void debugReset() => _laufend = null;

  /// Führt [ablauf] unter der Sperre aus. Prüfen und Setzen geschehen
  /// synchron vor dem ersten `await`, freigegeben wird in jedem Fall.
  Future<GptomLoginResult> _gesperrt(
    Future<GptomLoginResult> Function() ablauf,
  ) async {
    if (_laufend != null) {
      return const GptomLoginResult(outcome: GptomLoginOutcome.busy);
    }
    final marke = Object();
    _laufend = marke;
    try {
      return await ablauf();
    } finally {
      if (identical(_laufend, marke)) _laufend = null;
    }
  }

  /// Prüft die GP tom App: auf Android Installation, Signatur und Version,
  /// auf iOS nur, ob sich `gptom://` öffnen lässt.
  ///
  /// Achtung (Android): Ohne konfigurierte Pins merkt sich der erste Aufruf
  /// den Fingerprint der Signatur (trust on first use).
  Future<GptomAppCheck> checkGpTomApp({bool isDevAndroid = false}) =>
      _plattform.checkGpTomApp(isDevAndroid: isDevAndroid);

  /// Fragt den Zustand von GP tom ab. `null`, wenn kein Ergebnis kam
  /// (Service fehlt, Timeout, Fehler).
  ///
  /// Android: bindet den Info-Service bei Bedarf; [timeout] ist die Frist des
  /// nativen Wächters (Standard 20 s). iOS: `gptom://status` mit Redirect
  /// (Standard 30 s), wechselt dafür kurz zu GP tom.
  Future<GpTomInfo?> getStatus({
    bool isDevAndroid = false,
    Duration? timeout,
  }) async =>
      (await _statusAbfragen(isDevAndroid: isDevAndroid, timeout: timeout))
          .info;

  /// Status mit Grund, falls keiner kam. Android: [GptomLoginOutcome.notSupported]
  /// (Info-Service fehlt), [GptomLoginOutcome.timeout] (Wächter) oder
  /// [GptomLoginOutcome.failed]. iOS: Fehler aus [GptomIosAccount.status].
  Future<({GpTomInfo? info, GptomLoginOutcome? fehler})> _statusAbfragen({
    required bool isDevAndroid,
    Duration? timeout,
  }) async {
    if (_ios) return GptomIosAccount.status(timeout: timeout);
    final plattform = _plattform;
    try {
      if (!await plattform.bindInfoService(isDevAndroid: isDevAndroid)) {
        return (info: null, fehler: GptomLoginOutcome.notSupported);
      }
      final info = await plattform.getGpTomInfo(
        timeout: timeout ?? defaultStatusTimeoutAndroid,
      );
      if (info == null) return (info: null, fehler: GptomLoginOutcome.failed);
      return (info: info, fehler: null);
    } on PlatformException catch (e) {
      return (
        info: null,
        fehler: e.code == GptomErrorCode.timeout
            ? GptomLoginOutcome.timeout
            : GptomLoginOutcome.failed,
      );
    }
  }

  /// Meldet GP tom mit [credentials] an und wartet auf den Ausgang
  /// (Standard 60 s).
  ///
  /// [authCode] ist der Mail-Code nach [GptomLoginOutcome.tidReleaseRequired]
  /// (nur Android). Auf iOS gibt es keine TID-Freigabe per Code; mit
  /// [authCode] liefert der Aufruf [GptomLoginOutcome.invalidArgument], ohne
  /// GP tom zu öffnen.
  Future<GptomLoginResult> login(
    GptomCredentials credentials, {
    String? authCode,
    bool isDevAndroid = false,
    Duration? timeout,
  }) =>
      _gesperrt(() => _login(
            credentials,
            authCode: authCode,
            isDevAndroid: isDevAndroid,
            timeout: timeout,
          ));

  /// Login ohne Sperre (für [ensureLoggedIn], das die Sperre schon hält).
  Future<GptomLoginResult> _login(
    GptomCredentials c, {
    String? authCode,
    required bool isDevAndroid,
    Duration? timeout,
  }) {
    if (_ios) {
      if (authCode != null) {
        return Future.value(const GptomLoginResult(
          outcome: GptomLoginOutcome.invalidArgument,
          message: 'Auf iOS gibt es keine TID-Freigabe per Code.',
        ));
      }
      return GptomIosAccount.login(c, timeout: timeout);
    }
    return _androidKonto(
      op: GptomAccountOperation.login,
      isDevAndroid: isDevAndroid,
      timeout: timeout,
      aufruf: (p) => p.loginGpTom(
        username: c.username,
        password: c.password,
        terminalId: c.terminalId,
        authCode: authCode,
      ),
    );
  }

  /// Meldet GP tom ab und wartet auf den Ausgang (Standard 60 s).
  Future<GptomLoginResult> logout({
    bool isDevAndroid = false,
    Duration? timeout,
  }) =>
      _gesperrt(() {
        if (_ios) return GptomIosAccount.logout(timeout: timeout);
        return _androidKonto(
          op: GptomAccountOperation.logout,
          isDevAndroid: isDevAndroid,
          timeout: timeout,
          aufruf: (p) => p.logoutGpTom(),
        );
      });

  /// Passwortwechsel in zwei Stufen: ohne [code] schickt GP tom einen Code
  /// per Mail ([GptomLoginOutcome.passwordPendingConfirmation]), mit [code]
  /// wird das Passwort gesetzt. Ein leerer [code] zählt wie keiner.
  ///
  /// Android: Stufe 1 sendet `validationOnly: true` ohne `authCode`, Stufe 2
  /// `validationOnly: false` mit `authCode: code`. [username] und
  /// [terminalId] braucht nur iOS.
  Future<GptomLoginResult> changePassword({
    required String username,
    required String currentPassword,
    required String newPassword,
    required String terminalId,
    String? code,
    bool isDevAndroid = false,
    Duration? timeout,
  }) =>
      _gesperrt(() {
        if (_ios) {
          return GptomIosAccount.changePassword(
            username: username,
            currentPassword: currentPassword,
            newPassword: newPassword,
            terminalId: terminalId,
            code: code,
            timeout: timeout,
          );
        }
        final mitCode = code != null && code.isNotEmpty;
        return _androidKonto(
          op: GptomAccountOperation.changePassword,
          isDevAndroid: isDevAndroid,
          timeout: timeout,
          aufruf: (p) => p.changeGpTomPassword(
            currentPassword: currentPassword,
            newPassword: newPassword,
            authCode: mitCode ? code : null,
            validationOnly: !mitCode,
          ),
        );
      });

  /// Morgen-Check: prüft App und Status und meldet GP tom nur bei Bedarf an.
  ///
  /// 1. App nicht installiert → [GptomLoginOutcome.notInstalled], nicht
  ///    vertrauenswürdig → [GptomLoginOutcome.untrustedApp].
  /// 2. Kein Status → der Grund (z. B. [GptomLoginOutcome.notSupported],
  ///    [GptomLoginOutcome.timeout]).
  /// 3. Angemeldet: passt die TID zu [expectedTerminalId] (getrimmt; ohne
  ///    Angabe oder ohne TID im Status passt sie immer) →
  ///    [GptomLoginOutcome.alreadyLoggedIn], sonst
  ///    [GptomLoginOutcome.otherTerminal] ohne Umschalten.
  /// 4. Angemeldet ohne Netz → [GptomLoginOutcome.offline], kein Login.
  /// 5. Abgemeldet oder unbekannt → [credentials] aufrufen; `null` ergibt
  ///    [GptomLoginOutcome.noCredentials], sonst das Ergebnis von [login].
  ///
  /// [credentials] wird erst in Schritt 5 aufgerufen; Exceptions daraus
  /// werden weitergereicht. Das Ergebnis trägt in `info` den Status aus
  /// Schritt 2. [timeout] gilt je Schritt (Status und Login).
  Future<GptomLoginResult> ensureLoggedIn({
    required FutureOr<GptomCredentials?> Function() credentials,
    String? expectedTerminalId,
    bool isDevAndroid = false,
    Duration? timeout,
  }) =>
      _gesperrt(() async {
        final abgelehnt = await _appPruefen(isDevAndroid);
        if (abgelehnt != null) return abgelehnt;

        final status = await _statusAbfragen(
          isDevAndroid: isDevAndroid,
          timeout: timeout,
        );
        final info = status.info;
        if (info == null) {
          return GptomLoginResult(
            outcome: status.fehler ?? GptomLoginOutcome.failed,
          );
        }

        switch (info.loginState) {
          case GptomLoginState.loggedIn:
            return GptomLoginResult(
              outcome: _tidPasst(expectedTerminalId, info.tid)
                  ? GptomLoginOutcome.alreadyLoggedIn
                  : GptomLoginOutcome.otherTerminal,
              info: info,
            );
          case GptomLoginState.unverifiedLoggedIn:
            return GptomLoginResult(
              outcome: GptomLoginOutcome.offline,
              info: info,
            );
          case GptomLoginState.loggedOut:
          case GptomLoginState.unknown:
            final zugang = await credentials();
            if (zugang == null) {
              return GptomLoginResult(
                outcome: GptomLoginOutcome.noCredentials,
                info: info,
              );
            }
            final ergebnis = await _login(
              zugang,
              isDevAndroid: isDevAndroid,
              timeout: timeout,
            );
            return ergebnis.withInfo(info);
        }
      });

  /// Ohne erwartete TID oder ohne TID im Status passt sie immer.
  static bool _tidPasst(String? erwartet, String? tid) {
    final soll = erwartet?.trim() ?? '';
    final ist = tid?.trim() ?? '';
    if (soll.isEmpty || ist.isEmpty) return true;
    return soll == ist;
  }

  /// `null`, wenn die App installiert und vertrauenswürdig ist, sonst das
  /// Ergebnis, mit dem abgebrochen wird.
  Future<GptomLoginResult?> _appPruefen(bool isDevAndroid) async {
    final GptomAppCheck pruefung;
    try {
      pruefung = await _plattform.checkGpTomApp(isDevAndroid: isDevAndroid);
    } on PlatformException {
      return const GptomLoginResult(
        outcome: GptomLoginOutcome.failed,
        message: 'GP tom App konnte nicht geprüft werden.',
      );
    }
    if (!pruefung.installed) {
      return const GptomLoginResult(outcome: GptomLoginOutcome.notInstalled);
    }
    if (!pruefung.trusted) {
      return const GptomLoginResult(outcome: GptomLoginOutcome.untrustedApp);
    }
    return null;
  }

  /// Android: App prüfen, Login-Service binden, auf dem Login-Strom horchen,
  /// nativ aufrufen und auf das erste passende Ereignis warten.
  Future<GptomLoginResult> _androidKonto({
    required GptomAccountOperation op,
    required bool isDevAndroid,
    required Duration? timeout,
    required Future<bool> Function(GptomAidlPluginPlatform p) aufruf,
  }) async {
    // Erst prüfen: an eine fremde oder fehlende App gehen keine Zugangsdaten.
    final abgelehnt = await _appPruefen(isDevAndroid);
    if (abgelehnt != null) return abgelehnt;

    final plattform = _plattform;
    bool gebunden;
    try {
      gebunden = await plattform.bindLoginService(isDevAndroid: isDevAndroid);
    } on PlatformException {
      gebunden = false;
    }
    if (!gebunden) {
      return const GptomLoginResult(outcome: GptomLoginOutcome.notSupported);
    }

    final ergebnis = Completer<GptomLoginResult>();
    void beenden(GptomLoginResult r) {
      if (!ergebnis.isCompleted) ergebnis.complete(r);
    }

    // Vor dem Aufruf horchen, sonst geht ein schnelles Ereignis verloren.
    final abo = plattform.loginStatusStream.listen((e) {
      if (androidStatusBeendet(op, e.rawStatus)) {
        beenden(GptomLoginResult(
          outcome: outcomeFromAndroidStatus(e.rawStatus),
          rawStatus: e.rawStatus,
          message: e.message,
        ));
      }
    });
    try {
      // Der Wächter läuft ab jetzt und deckt auch einen hängenden nativen
      // Aufruf ab. Dessen Fehlertext kann Zugangsdaten enthalten und wird
      // deshalb durch einen festen Text ersetzt.
      unawaited(Future<bool>.sync(() => aufruf(plattform)).then(
        (angenommen) {
          if (!angenommen) beenden(_nichtUebergeben(op));
        },
        onError: (Object fehler, StackTrace stack) {
          if (fehler is PlatformException) {
            beenden(_nichtUebergeben(op));
          } else if (!ergebnis.isCompleted) {
            ergebnis.completeError(fehler, stack);
          }
        },
      ));
      return await ergebnis.future.timeout(
        timeout ?? defaultAccountTimeout,
        onTimeout: () =>
            const GptomLoginResult(outcome: GptomLoginOutcome.timeout),
      );
    } finally {
      await abo.cancel();
    }
  }

  static GptomLoginResult _nichtUebergeben(GptomAccountOperation op) =>
      GptomLoginResult(
        outcome: GptomLoginOutcome.failed,
        message: switch (op) {
          GptomAccountOperation.login =>
            'Login konnte nicht an GP tom übergeben werden.',
          GptomAccountOperation.logout =>
            'Logout konnte nicht an GP tom übergeben werden.',
          GptomAccountOperation.changePassword =>
            'Passwortwechsel konnte nicht an GP tom übergeben werden.',
        },
      );
}
