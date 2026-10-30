import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'gptom_aidl_plugin_ios.dart';
import 'models/gptom_info.dart';
import 'models/gptom_login.dart';

/// Login, Logout, Passwortwechsel und Status von GP tom auf iOS über das
/// URL-Scheme `gptom://`.
///
/// Achtung: Das Passwort reist – so ist es bei GP tom vorgesehen – als
/// Query-Parameter in der `gptom://`-URL. Die URL erscheint deshalb in keiner
/// Fehlermeldung und keinem Log. Jeder Aufruf wechselt zu GP tom und über den
/// Redirect zurück in die eigene App.
///
/// Die Antwort wird über denselben Redirect-Mechanismus wie bei Zahlungen
/// zugeordnet (Token in der `redirectUrl`).
class GptomIosAccount {
  GptomIosAccount._();

  /// Standard-Wartezeit für Login, Logout und Passwortwechsel.
  static const Duration defaultAccountTimeout = Duration(seconds: 60);

  /// Standard-Wartezeit für die Statusabfrage.
  static const Duration defaultStatusTimeout = Duration(seconds: 30);

  /// Query selbst bauen: `Uri.encodeComponent` kodiert Leerzeichen als `%20`
  /// (nie `+`) und `+`, `&`, `%`, `#` zuverlässig.
  static Uri _bauen(String pfad, List<MapEntry<String, String>> felder) {
    final query = felder
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return Uri.parse('gptom://$pfad?$query');
  }

  @visibleForTesting
  static Uri buildLoginUri({
    required String username,
    required String password,
    required String terminalId,
    required String redirectUrl,
  }) =>
      _bauen('login', [
        MapEntry('username', username),
        MapEntry('password', password),
        MapEntry('tid', terminalId),
        MapEntry('redirectUrl', redirectUrl),
      ]);

  /// [code] (Mail-Code, zweite Stufe) nur, wenn nicht leer.
  @visibleForTesting
  static Uri buildChangePasswordUri({
    required String username,
    required String password,
    required String newPassword,
    required String terminalId,
    String? code,
    required String redirectUrl,
  }) =>
      _bauen('change-password', [
        MapEntry('username', username),
        MapEntry('password', password),
        MapEntry('newPassword', newPassword),
        MapEntry('tid', terminalId),
        if (code != null && code.isNotEmpty) MapEntry('code', code),
        MapEntry('redirectUrl', redirectUrl),
      ]);

  @visibleForTesting
  static Uri buildLogoutUri({required String redirectUrl}) =>
      _bauen('logout', [MapEntry('redirectUrl', redirectUrl)]);

  @visibleForTesting
  static Uri buildStatusUri({required String redirectUrl}) =>
      _bauen('status', [MapEntry('redirectUrl', redirectUrl)]);

  /// Bildet `status`/`error` des Redirects auf ein Ergebnis ab.
  @visibleForTesting
  static GptomLoginResult loginResultFromRedirect(
    Uri uri,
    GptomAccountOperation op, {
    bool codeGesendet = false,
  }) {
    final status = uri.queryParameters['status'];
    final error = uri.queryParameters['error'];
    return GptomLoginResult(
      outcome: outcomeFromIosRedirect(
        op: op,
        status: status,
        error: error,
        codeGesendet: codeGesendet,
      ),
      rawStatus: status,
      rawError: error,
    );
  }

  /// Liest `appStatus` (JSON) des Redirects; fehlend oder kaputt: `null`.
  @visibleForTesting
  static GpTomInfo? infoFromStatusRedirect(Uri uri) {
    final roh = uri.queryParameters['appStatus'];
    if (roh == null || roh.isEmpty) return null;
    try {
      final decoded = jsonDecode(roh);
      if (decoded is! Map) return null;
      return GpTomInfo.fromIosAppStatus(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static Future<GptomLoginResult> _ausfuehren(
    Uri Function(String redirectUrl) bauen,
    GptomAccountOperation op,
    Duration timeout, {
    bool codeGesendet = false,
  }) async {
    if (!GptomAidlPluginIOS.isActive) {
      return const GptomLoginResult(outcome: GptomLoginOutcome.cannotOpen);
    }
    final antwort = await GptomAidlPluginIOS.roundtrip(bauen, timeout: timeout);
    if (antwort.cannotOpen) {
      return const GptomLoginResult(outcome: GptomLoginOutcome.cannotOpen);
    }
    final redirect = antwort.redirect;
    if (redirect == null) {
      return const GptomLoginResult(outcome: GptomLoginOutcome.timeout);
    }
    return loginResultFromRedirect(redirect, op, codeGesendet: codeGesendet);
  }

  /// Meldet den Benutzer an dem Terminal an.
  static Future<GptomLoginResult> login(
    GptomCredentials c, {
    Duration? timeout,
  }) =>
      _ausfuehren(
        (r) => buildLoginUri(
          username: c.username,
          password: c.password,
          terminalId: c.terminalId,
          redirectUrl: r,
        ),
        GptomAccountOperation.login,
        timeout ?? defaultAccountTimeout,
      );

  static Future<GptomLoginResult> logout({Duration? timeout}) => _ausfuehren(
        (r) => buildLogoutUri(redirectUrl: r),
        GptomAccountOperation.logout,
        timeout ?? defaultAccountTimeout,
      );

  /// Passwortwechsel in zwei Stufen: erst ohne [code] (GP tom schickt den
  /// Mail-Code), dann mit [code].
  static Future<GptomLoginResult> changePassword({
    required String username,
    required String currentPassword,
    required String newPassword,
    required String terminalId,
    String? code,
    Duration? timeout,
  }) =>
      _ausfuehren(
        (r) => buildChangePasswordUri(
          username: username.trim(),
          password: currentPassword,
          newPassword: newPassword,
          terminalId: terminalId.trim(),
          code: code,
          redirectUrl: r,
        ),
        GptomAccountOperation.changePassword,
        timeout ?? defaultAccountTimeout,
        codeGesendet: code != null && code.isNotEmpty,
      );

  /// Fragt den Zustand von GP tom ab. Bei Erfolg [info], sonst [fehler]
  /// (`cannotOpen`, `timeout`, `cancelled`, `offline`, `failed` oder
  /// `unknown`).
  ///
  /// `status=ERROR` mit `error=userNotLoggedIn` ist kein Fehler, sondern der
  /// Zustand „abgemeldet“ – sonst würde der Morgen-Check nie anmelden.
  /// `networkError` ergibt `offline`, jeder andere `ERROR` `failed`.
  /// `COMPLETED` ohne lesbaren `appStatus` bleibt `unknown`.
  static Future<({GpTomInfo? info, GptomLoginOutcome? fehler})> status({
    Duration? timeout,
  }) async {
    if (!GptomAidlPluginIOS.isActive) {
      return (info: null, fehler: GptomLoginOutcome.cannotOpen);
    }
    final antwort = await GptomAidlPluginIOS.roundtrip(
      (r) => buildStatusUri(redirectUrl: r),
      timeout: timeout ?? defaultStatusTimeout,
    );
    if (antwort.cannotOpen) {
      return (info: null, fehler: GptomLoginOutcome.cannotOpen);
    }
    final redirect = antwort.redirect;
    if (redirect == null) {
      return (info: null, fehler: GptomLoginOutcome.timeout);
    }
    final st = redirect.queryParameters['status']?.toUpperCase();
    if (st == 'CANCELLED' || st == 'CANCELED') {
      return (info: null, fehler: GptomLoginOutcome.cancelled);
    }
    if (st == 'ERROR') {
      switch (redirect.queryParameters['error']) {
        case 'userNotLoggedIn':
          return (
            info: GpTomInfo(
              loginState: GptomLoginState.loggedOut,
              isLoggedIn: false,
            ),
            fehler: null,
          );
        case 'networkError':
          return (info: null, fehler: GptomLoginOutcome.offline);
        default:
          return (info: null, fehler: GptomLoginOutcome.failed);
      }
    }
    final info = infoFromStatusRedirect(redirect);
    if (info == null) return (info: null, fehler: GptomLoginOutcome.unknown);
    return (info: info, fehler: null);
  }
}
