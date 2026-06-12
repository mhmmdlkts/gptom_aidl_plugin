import 'dart:convert';

/// Infos über die installierte GP tom App (IGPTomInfoService.getGPTomInfo,
/// entspricht App2AppInfoResponse aus der AIDL-Bibliothek).
class GpTomInfo {
  final String? appVersion;
  final bool isLoggedIn;

  /// LOGGED_IN, LOGGED_OUT oder UNVERIFIED_LOGGED_IN
  final String? logInStatus;
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

  /// Die komplette Antwort, falls GP tom weitere Felder liefert.
  final Map<String, dynamic> raw;

  GpTomInfo({
    this.appVersion,
    this.isLoggedIn = false,
    this.logInStatus,
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
    this.raw = const {},
  });

  factory GpTomInfo.fromMap(Map<String, dynamic> map) {
    return GpTomInfo(
      appVersion: map['appVersion'] as String?,
      isLoggedIn: map['isLoggedIn'] == true,
      logInStatus: map['logInStatus'] as String?,
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
      raw: map,
    );
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
