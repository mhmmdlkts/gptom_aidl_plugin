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

  // --- Szenario-Handler (optional, haben Vorrang) ----------------------------
  RegisterResult Function(Map<String, dynamic> params)? onRegister;
  RequestResult Function(Map<String, dynamic> params)? onRequest;
  StateResult Function(String transactionId)? onStateRequest;
  InquireResult Function(String transactionId)? onInquire;

  final StreamController<GpTomLoginEvent> _loginStatusController =
      StreamController<GpTomLoginEvent>.broadcast();
  final StreamController<GpTomInfo> _gpTomInfoController =
      StreamController<GpTomInfo>.broadcast();

  /// Simuliert einen Login-Status-Push aus der GP tom App.
  void emitLoginStatus(GpTomLoginEvent event) => _loginStatusController.add(event);

  /// Simuliert einen Info-Push aus der GP tom App.
  void emitGpTomInfo(GpTomInfo info) => _gpTomInfoController.add(info);

  // --- GptomAidlPluginPlatform ----------------------------------------------
  @override
  Future<bool> existGpTomApp({bool isDevAndroid = false}) async => existsGpTomApp;

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
    loginCalls.add({
      'username': username,
      'password': password,
      'terminalId': terminalId,
      'authCode': authCode,
    });
    return loginResult;
  }

  @override
  Future<bool> logoutGpTom() async {
    logoutCalls++;
    return logoutResult;
  }

  @override
  Future<bool> changeGpTomPassword({
    required String currentPassword,
    required String newPassword,
    String? authCode,
    bool validationOnly = false,
  }) async {
    changePasswordCalls.add({
      'currentPassword': currentPassword,
      'newPassword': newPassword,
      'authCode': authCode,
      'validationOnly': validationOnly,
    });
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
  Future<GpTomInfo?> getGpTomInfo() async {
    getGpTomInfoCalls++;
    return gpTomInfo;
  }

  @override
  Stream<GpTomInfo> get gpTomInfoStream => _gpTomInfoController.stream;

  /// Schließt die internen Stream-Controller (z. B. in tearDown).
  Future<void> dispose() async {
    await _loginStatusController.close();
    await _gpTomInfoController.close();
  }
}
