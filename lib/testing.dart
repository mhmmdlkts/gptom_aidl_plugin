/// Test-Helfer für Apps, die dieses Plugin nutzen.
///
/// In App-Tests lässt sich damit prüfen, ob die eigenen Aufrufe (insbesondere
/// Beleg-Daten wie `preferableReceiptType`, `clientInfo`, `printByPaymentApp`
/// oder die Cent-Beträge) korrekt beim Plugin ankommen – ohne Gerät und ohne
/// GP tom App:
///
/// ```dart
/// final fake = FakeGptomAidlPluginPlatform();
/// GptomAidlPluginPlatform.instance = fake;
///
/// await GptomAidlPlugin().sell(
///   transactionIdAndroid: 'tx-1',
///   amountCents: 1250,
///   transactionMethode: TransactionMethode.card,
///   clientInfo: {'email': 'kunde@example.com'},
/// );
///
/// final params = fake.requestCalls.single;
/// expect(params['amount'], 1250);
/// expect(params['clientInfo']['contact']['email'], 'kunde@example.com');
/// ```
library;

import 'dart:async';

import 'models/gptom_app_check.dart';
import 'models/gptom_info.dart';
import 'models/inquire_result.dart';
import 'models/login_status.dart';
import 'models/register_result.dart';
import 'models/request_result.dart';
import 'models/state_result.dart';
import 'gptom_aidl_plugin_platform_interface.dart';

export 'gptom_aidl_plugin_platform_interface.dart';

/// Zeichnet alle Aufrufe auf und liefert konfigurierbare Antworten.
class FakeGptomAidlPluginPlatform extends GptomAidlPluginPlatform {
  // --- Aufgezeichnete Aufrufe -----------------------------------------------
  final List<Map<String, dynamic>> registerCalls = [];
  final List<Map<String, dynamic>> requestCalls = [];
  final List<String> stateRequests = [];
  final List<String> inquireRequests = [];
  final List<Map<String, Object?>> loginCalls = [];
  final List<Map<String, Object?>> changePasswordCalls = [];
  int bindServiceCalls = 0;
  int unbindServiceCalls = 0;
  int bindLoginServiceCalls = 0;
  int unbindLoginServiceCalls = 0;
  int bindInfoServiceCalls = 0;
  int unbindInfoServiceCalls = 0;
  int logoutCalls = 0;
  int getGpTomInfoCalls = 0;
  int checkGpTomAppCalls = 0;
  /// isDev je Aufruf von openApp.
  final List<bool> openAppCalls = [];
  /// Antwort von openApp.
  bool openAppResult = true;
  int resetTrustedSignatureCalls = 0;
  final List<Duration?> getGpTomInfoTimeouts = [];

  // --- Konfigurierbare Antworten --------------------------------------------
  // Für Szenarien (z. B. "erst abgelehnt, dann erfolgreich" oder ein
  // Status-Verlauf CREATED -> IN_PROGRESS -> COMPLETED) gibt es zusätzlich
  // die on...-Handler; sie haben Vorrang vor den statischen Ergebnissen.
  bool existsGpTomApp = true;
  bool bindServiceResult = true;
  bool bindLoginServiceResult = true;
  bool bindInfoServiceResult = true;
  bool loginResult = true;
  bool logoutResult = true;
  bool changePasswordResult = true;

  RegisterResult registerResult = RegisterResult(resultCode: 0, transactionId: 'fake-tx');
  RequestResult requestResult = RequestResult(result: 0);
  StateResult stateResult = StateResult(resultCode: 0, state: StateStatus.completed);
  InquireResult inquireResult = InquireResult(
    result: 0,
    transactionId: 'fake-tx',
    amountCents: 0,
    tipAmountCents: 0,
  );
  GpTomInfo? gpTomInfo;
  GptomAppCheck appCheck = const GptomAppCheck(
    installed: true,
    trusted: true,
    source: GptomTrustSource.pinned,
  );

  /// Wird von [getGpTomInfo] geworfen, wenn gesetzt (z. B. eine
  /// `PlatformException` mit Code `TIMEOUT`).
  Object? getGpTomInfoError;

  // --- Szenario-Handler (optional, haben Vorrang) ----------------------------
  RegisterResult Function(Map<String, dynamic> params)? onRegister;
  RequestResult Function(Map<String, dynamic> params)? onRequest;
  StateResult Function(String transactionId)? onStateRequest;
  InquireResult Function(String transactionId)? onInquire;

  /// Login-/Logout-/Passwort-Handler: Ein zurückgegebenes Ereignis wird nach
  /// dem Aufzeichnen des Aufrufs per Microtask in [loginStatusStream]
  /// gegeben, `null` sendet nichts.
  GpTomLoginEvent? Function(Map<String, Object?> call)? onLogin;
  GpTomLoginEvent? Function()? onLogout;
  GpTomLoginEvent? Function(Map<String, Object?> call)? onChangePassword;

  final StreamController<GpTomLoginEvent> _loginStatusController =
      StreamController<GpTomLoginEvent>.broadcast();
  final StreamController<GpTomInfo> _gpTomInfoController =
      StreamController<GpTomInfo>.broadcast();
  final StreamController<RequestResult> _lateTransactionController =
      StreamController<RequestResult>.broadcast();

  /// Simuliert einen Login-Status-Push aus der GP tom App.
  void emitLoginStatus(GpTomLoginEvent event) => _loginStatusController.add(event);

  /// Simuliert einen Info-Push aus der GP tom App.
  void emitGpTomInfo(GpTomInfo info) => _gpTomInfoController.add(info);

  /// Simuliert ein Ergebnis, das GP tom erst nach dem Wächter-Timeout
  /// geliefert hat – damit lässt sich der Fall "unklar, dann doch bezahlt"
  /// in App-Tests durchspielen.
  void emitLateTransactionResult(RequestResult result) =>
      _lateTransactionController.add(result);

  // --- GptomAidlPluginPlatform ----------------------------------------------
  @override
  Future<bool> existGpTomApp({bool isDevAndroid = false}) async => existsGpTomApp;

  @override
  Future<bool> openApp({bool isDevAndroid = false}) async {
    openAppCalls.add(isDevAndroid);
    return openAppResult;
  }

  @override
  Future<GptomAppCheck> checkGpTomApp({bool isDevAndroid = false}) async {
    checkGpTomAppCalls++;
    return appCheck;
  }

  @override
  Future<bool> resetTrustedSignature({bool isDevAndroid = false}) async {
    resetTrustedSignatureCalls++;
    return true;
  }

  void _sendeLoginEreignis(GpTomLoginEvent? event) {
    if (event != null) {
      scheduleMicrotask(() => _loginStatusController.add(event));
    }
  }

  @override
  Future<bool> bindService({bool isDevAndroid = false}) async {
    bindServiceCalls++;
    return bindServiceResult;
  }

  @override
  Future<void> unbindService() async {
    unbindServiceCalls++;
  }

  @override
  Future<RegisterResult> registerTransactionV2Android(Map<String, dynamic> params) async {
    registerCalls.add(params);
    return onRegister?.call(params) ?? registerResult;
  }

  @override
  Future<RequestResult> requestTransactionV2Android(Map<String, dynamic> params) async {
    requestCalls.add(params);
    return onRequest?.call(params) ?? requestResult;
  }

  @override
  Future<StateResult> stateRequestAndroid(String transactionId) async {
    stateRequests.add(transactionId);
    return onStateRequest?.call(transactionId) ?? stateResult;
  }

  @override
  Future<InquireResult> inquireTransactionAndroid(String transactionId) async {
    inquireRequests.add(transactionId);
    return onInquire?.call(transactionId) ?? inquireResult;
  }

  @override
  Future<bool> createTransactionIOS() async => true;

  @override
  Future<bool> cancelTransactionIOS() async => true;

  @override
  Future<bool> bindLoginService({bool isDevAndroid = false}) async {
    bindLoginServiceCalls++;
    return bindLoginServiceResult;
  }

  @override
  Future<void> unbindLoginService() async {
    unbindLoginServiceCalls++;
  }

  @override
  Future<bool> loginGpTom({
    required String username,
    required String password,
    required String terminalId,
    String? authCode,
  }) async {
    final call = <String, Object?>{
      'username': username,
      'password': password,
      'terminalId': terminalId,
      'authCode': authCode,
    };
    loginCalls.add(call);
    _sendeLoginEreignis(onLogin?.call(call));
    return loginResult;
  }

  @override
  Future<bool> logoutGpTom() async {
    logoutCalls++;
    _sendeLoginEreignis(onLogout?.call());
    return logoutResult;
  }

  @override
  Future<bool> changeGpTomPassword({
    required String currentPassword,
    required String newPassword,
    String? authCode,
    bool validationOnly = false,
  }) async {
    final call = <String, Object?>{
      'currentPassword': currentPassword,
      'newPassword': newPassword,
      'authCode': authCode,
      'validationOnly': validationOnly,
    };
    changePasswordCalls.add(call);
    _sendeLoginEreignis(onChangePassword?.call(call));
    return changePasswordResult;
  }

  @override
  Stream<GpTomLoginEvent> get loginStatusStream => _loginStatusController.stream;

  @override
  Future<bool> bindInfoService({bool isDevAndroid = false}) async {
    bindInfoServiceCalls++;
    return bindInfoServiceResult;
  }

  @override
  Future<void> unbindInfoService() async {
    unbindInfoServiceCalls++;
  }

  @override
  Future<GpTomInfo?> getGpTomInfo({Duration? timeout}) async {
    getGpTomInfoCalls++;
    getGpTomInfoTimeouts.add(timeout);
    final fehler = getGpTomInfoError;
    if (fehler != null) {
      throw fehler;
    }
    return gpTomInfo;
  }

  @override
  Stream<GpTomInfo> get gpTomInfoStream => _gpTomInfoController.stream;

  @override
  Stream<RequestResult> get lateTransactionResultStream =>
      _lateTransactionController.stream;

  /// Schließt die internen Stream-Controller (z. B. in tearDown).
  Future<void> dispose() async {
    await _loginStatusController.close();
    await _gpTomInfoController.close();
    await _lateTransactionController.close();
  }
}
