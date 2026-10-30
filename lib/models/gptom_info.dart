import 'dart:convert';

import 'gptom_login.dart';

/// Infos über die installierte GP tom App (IGPTomInfoService.getGPTomInfo,
/// entspricht App2AppInfoResponse aus der AIDL-Bibliothek).
class GpTomInfo {
  final String? appVersion;
  final bool isLoggedIn;

  /// LOGGED_IN, LOGGED_OUT oder UNVERIFIED_LOGGED_IN
  final String? logInStatus;

  /// Eindeutiger Anmeldezustand (Android aus `logInStatus`, iOS aus `userInfo`).
  final GptomLoginState loginState;
  final String? tid;
  final String? mid;
  final String? clientId;
  final String? businessId;
  final String? email;
  final String? vat;
  final bool? tipEnabled;
  final bool? printerAvailable;
  final bool? manualTransactionRestricted;
  final Map<String, dynamic>? merchantLocationEntity;

  /// `merchantLocation` als Text, wie GP tom es liefert (nur wenn String).
  final String? merchantLocationText;

  /// Die komplette Antwort, falls GP tom weitere Felder liefert.
  final Map<String, dynamic> raw;

  GpTomInfo({
    this.appVersion,
    this.isLoggedIn = false,
    this.logInStatus,
    this.loginState = GptomLoginState.unknown,
    this.tid,
    this.mid,
    this.clientId,
    this.businessId,
    this.email,
    this.vat,
    this.tipEnabled,
    this.printerAvailable,
    this.manualTransactionRestricted,
    this.merchantLocationEntity,
    this.merchantLocationText,
    this.raw = const {},
  });

  factory GpTomInfo.fromMap(Map<String, dynamic> map) {
    return GpTomInfo(
      appVersion: map['appVersion'] as String?,
      isLoggedIn: map['isLoggedIn'] == true,
      logInStatus: map['logInStatus'] as String?,
      loginState: GptomLoginState.fromAndroid(
        map['logInStatus'] as String?,
        isLoggedIn: map['isLoggedIn'],
      ),
      tid: map['tid'] as String?,
      mid: map['mid'] as String?,
      clientId: map['clientId'] as String?,
      businessId: map['businessId'] as String?,
      email: map['email'] as String?,
      vat: map['vat'] as String?,
      tipEnabled: map['tipEnabled'] as bool?,
      printerAvailable: map['printerAvailable'] as bool?,
      manualTransactionRestricted: map['manualTransactionRestricted'] as bool?,
      merchantLocationEntity: map['merchantLocationEntity'] != null
          ? Map<String, dynamic>.from(map['merchantLocationEntity'])
          : null,
      merchantLocationText: map['merchantLocation'] is String
          ? map['merchantLocation'] as String
          : null,
      raw: map,
    );
  }

  /// iOS: aus `appStatus` der Antwort auf `gptom://status`. Fehlt `userInfo`,
  /// ist GP tom abgemeldet.
  ///
  /// Fremd-Input, deshalb nachsichtig gelesen: Texte über `toString()` (eine
  /// TID als Zahl wird `'12345678'`), Wahrheitswerte als `true`/`false` oder
  /// `'true'`/`'false'`, sonst `null`. Ein unerwarteter Typ macht so nie den
  /// ganzen Status unlesbar.
  factory GpTomInfo.fromIosAppStatus(Map<String, dynamic> appStatus) {
    final u = appStatus['userInfo'];
    final user = u is Map ? Map<String, dynamic>.from(u) : null;
    final ort = user?['merchantLocation'];
    return GpTomInfo(
      appVersion: _text(appStatus['appVersion']),
      isLoggedIn: user != null,
      loginState:
          user != null ? GptomLoginState.loggedIn : GptomLoginState.loggedOut,
      tid: _text(user?['tid']),
      mid: _text(user?['mid']),
      clientId: _text(user?['clientId']),
      businessId: _text(user?['businessId']),
      email: _text(user?['email']),
      vat: _text(user?['vatId']),
      tipEnabled: _wahrheitswert(user?['tipEnabled']),
      printerAvailable: _wahrheitswert(user?['printerAvailable']),
      manualTransactionRestricted:
          _wahrheitswert(user?['manualTransactionRestricted']),
      merchantLocationEntity: ort is Map ? Map<String, dynamic>.from(ort) : null,
      raw: appStatus,
    );
  }

  static String? _text(Object? wert) => wert?.toString();

  static bool? _wahrheitswert(Object? wert) {
    if (wert is bool) return wert;
    if (wert is String) {
      switch (wert.trim().toLowerCase()) {
        case 'true':
          return true;
        case 'false':
          return false;
      }
    }
    return null;
  }

  factory GpTomInfo.fromJson(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is Map<String, dynamic>) {
      return GpTomInfo.fromMap(decoded);
    }
    return GpTomInfo();
  }

  @override
  String toString() =>
      'GpTomInfo(appVersion=$appVersion, isLoggedIn=$isLoggedIn, '
      'logInStatus=$logInStatus, tid=$tid, mid=$mid)';
}
