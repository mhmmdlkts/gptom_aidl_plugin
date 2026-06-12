import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';
import 'package:gptom_aidl_plugin/models/gptom_info.dart';
import 'package:gptom_aidl_plugin/models/inquire_result.dart';
import 'package:gptom_aidl_plugin/models/login_status.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';
import 'package:gptom_aidl_plugin/models/state_result.dart';

import 'enums/cancel_mode.dart';
import 'enums/preferable_receipt_type.dart';
import 'enums/transaction_methode.dart';
import 'gptom_aidl_plugin_platform_interface.dart';
import 'models/register_result.dart';

/// GptomAidlPlugin:
///   Dart-Fassade für alle relevanten GPTom/SmartConnect-Methoden.
///   Jede Methode nimmt die relevanten Parameter entgegen,
///   ruft das jeweilige PlatformInterface auf,
///   und gibt ein Future<String?> oder Future<Map<String,dynamic>?> zurück.
///
/// 1) registerTransaction
/// 2) requestTransaction
/// 3) stateRequest
/// 4) inquireTransaction
class GptomAidlPlugin {
  Future<bool> existGpTomApp({bool isDevAndroid = false}) {
    return GptomAidlPluginPlatform.instance.existGpTomApp(isDevAndroid: isDevAndroid);
  }

  // ---------------------------------------------------------------------------
  // Bind Service
  // ---------------------------------------------------------------------------
  Future<bool> bindService({bool isDevAndroid = false, String uriSchemeIOS = 'xxx'}) async {
    if (Platform.isIOS) {
      if (uriSchemeIOS.isEmpty || uriSchemeIOS == 'xxx') {
        throw ArgumentError(
          'uriSchemeIOS muss auf iOS gesetzt werden (das eigene URL-Scheme der App), '
          'sonst kann GPTom das Ergebnis nicht zurückliefern.',
        );
      }
      GptomAidlPluginIOS.listenForGptomRedirectsIOS(uriSchemeIOS);
      return Future.value(true);
    }
    return GptomAidlPluginPlatform.instance.bindService(isDevAndroid: isDevAndroid);
  }

  /// Gibt die Service-Verbindung(en) auf Android wieder frei.
  Future<void> unbindService() {
    return GptomAidlPluginPlatform.instance.unbindService();
  }

  // ---------------------------------------------------------------------------
  // 1) transactionRegisterV2
  // ---------------------------------------------------------------------------
  /// Registriert eine Transaktion und erhält eine transactionId.
  /// [clientId] (optional) muss zum angemeldeten Nutzer passen,
  /// andernfalls kann ein Fehler wie "ClientAPIDoesNotMatch" auftreten.
  Future<RegisterResult> registerTransactionV2Android({String? clientId}) async {
    // Baue ein Map, das später in JSON verwandelt wird:
    final params = <String, dynamic>{
      if (clientId != null) 'clientID': clientId,
      // ggf. weitere Felder
    };
    return GptomAidlPluginPlatform.instance.registerTransactionV2Android(params);
  }

  // ---------------------------------------------------------------------------
  // 2) transactionRequestV2
  // ---------------------------------------------------------------------------
  /// Startet eine Transaktion (Sale, Void, etc.).
  ///
  /// - [transactionId] muss von registerTransactionV2 kommen
  /// - [transactionType]: 1=SALE, 2=VOID, 3=REFUND, 4=CLOSE_BATCH, ...
  /// - [amount]: in EUR (wird intern in Cent umgerechnet, 11.11 => 1111)
  /// - [tipAmount] (optional)
  /// - [originTransactionId] (bei VOID/REFUND)
  /// - [cancelMode]: 1= letzte Transaktion, 2=ältere Transaktionen (ggf. optional)
  /// - [clientId]: falls nötig
  /// - [printByPaymentApp], [tipCollect], [redirectPackageName], [redirectInfo], ...
  Future<RequestResult> requestTransactionV2Android({
    required String transactionId,
    required TransactionType transactionType,
    double? amount,
    double? tipAmount,
    String? originTransactionId,
    CancelMode? cancelMode,
    String? clientId,
    bool? printByPaymentApp,
    bool? tipCollect,
    Map<String, dynamic>? redirectInfo,
    Map<String, dynamic>? clientInfo,
    bool openGptomUI = true,
    PreferableReceiptType? preferableReceiptType,
  }) async {
    final params = <String, dynamic>{
      'transactionID': transactionId,
      'transactionType': transactionType.id,
      // round() statt toInt(): toInt() schneidet ab und macht aus
      // 4.35 * 100 = 434.99999… sonst 434 Cent.
      if (amount != null) 'amount': (amount * 100).round(),
      'openGptomUI': openGptomUI,
      if (tipAmount != null) 'tipAmount': (tipAmount * 100).round(),
      if (originTransactionId != null) 'originTransactionID': originTransactionId,
      if (cancelMode != null) 'cancelMode': cancelMode.id,
      if (clientId != null) 'clientID': clientId,
      if (printByPaymentApp != null) 'printByPaymentApp': printByPaymentApp,
      if (tipCollect != null) 'tipCollect': tipCollect,
      if (redirectInfo != null) 'redirectInfo': redirectInfo,
      if (clientInfo != null) 'clientInfo': clientInfo,
      if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.key,
    };
    // Dann rufen wir das platform interface auf
    return GptomAidlPluginPlatform.instance.requestTransactionV2Android(params);
  }


  Future<RequestResult> sell({
    String? transactionIdAndroid,
    required double amount,
    required TransactionMethode transactionMethode,
    double tipAmount = 0,
    String? clientId,
    bool printByPaymentApp = false,
    bool tipCollect = false,
    bool openGptomUI = true,
    Map<String, dynamic>? redirectInfo,
    Map<String, dynamic>? clientInfo,
    PreferableReceiptType? preferableReceiptType,
  }) async {
    if (Platform.isIOS) {
      return await GptomAidlPluginIOS.createTransactionIOS(
        amount: amount,
        transactionMethode: transactionMethode,
        tipCollect: tipCollect,
        tipAmount: tipAmount,
        printByPaymentApp: printByPaymentApp,
        clientID: clientId,
        preferableReceiptType: preferableReceiptType,
        clientEmail: clientInfo?['email'],
        clientPhone: clientInfo?['phone'],
      );
    }
    if (transactionIdAndroid == null) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'transactionIdAndroid is required for sell',
      );
    }
    return requestTransactionV2Android(
      transactionId: transactionIdAndroid,
      transactionType: TransactionType.sell,
      amount: amount,
      tipAmount: tipAmount,
      clientId: clientId,
      printByPaymentApp: printByPaymentApp,
      tipCollect: tipCollect,
      redirectInfo: redirectInfo,
      clientInfo: clientInfo,
      openGptomUI: openGptomUI,
      preferableReceiptType: preferableReceiptType,
    );
  }


  Future<RequestResult> voidSell({
    String? transactionIdAndroid,
    required String originTransactionId,
    required CancelMode cancelMode,
    String? clientId,
    Map<String, dynamic>? redirectInfo,
    Map<String, dynamic>? clientInfo,
    bool openGptomUI = true,
    PreferableReceiptType? preferableReceiptType,
  }) async {
    if (Platform.isIOS) {
      return await GptomAidlPluginIOS.cancelTransactionIOS(
        amsID: originTransactionId,
        preferableReceiptType: preferableReceiptType,
        clientPhone: clientInfo?['phone'],
        clientEmail: clientInfo?['email'],
        clientID: clientId,
      );
    }
    if (transactionIdAndroid == null) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'transactionIdAndroid is required for voidSell',
      );
    }
    return requestTransactionV2Android(
      transactionId: transactionIdAndroid,
      originTransactionId: originTransactionId,
      transactionType: TransactionType.voidSell,
      clientId: clientId,
      redirectInfo: redirectInfo,
      clientInfo: clientInfo,
      cancelMode: cancelMode,
      openGptomUI: openGptomUI,
      preferableReceiptType: preferableReceiptType,
    );
  }

  /// Rückerstattung (REFUND, transactionType 3) einer abgeschlossenen
  /// Transaktion. Nur Android – auf iOS bietet das GPTom-URL-Scheme dafür
  /// keinen Weg.
  Future<RequestResult> refund({
    String? transactionIdAndroid,
    required String originTransactionId,
    required double amount,
    String? clientId,
    bool printByPaymentApp = false,
    Map<String, dynamic>? redirectInfo,
    Map<String, dynamic>? clientInfo,
    bool openGptomUI = true,
    PreferableReceiptType? preferableReceiptType,
  }) async {
    if (Platform.isIOS) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'refund is not supported on iOS',
      );
    }
    if (transactionIdAndroid == null) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'transactionIdAndroid is required for refund',
      );
    }
    return requestTransactionV2Android(
      transactionId: transactionIdAndroid,
      originTransactionId: originTransactionId,
      transactionType: TransactionType.refund,
      amount: amount,
      clientId: clientId,
      printByPaymentApp: printByPaymentApp,
      redirectInfo: redirectInfo,
      clientInfo: clientInfo,
      openGptomUI: openGptomUI,
      preferableReceiptType: preferableReceiptType,
    );
  }

  Future closeBatch({
    String? transactionIdAndroid,
    String? clientId,
    Map<String, dynamic>? redirectInfo,
    Map<String, dynamic>? clientInfo,
    bool openGptomUI = true,
    PreferableReceiptType? preferableReceiptType,
    bool printByPaymentApp = false,
  }) async {
    if (Platform.isIOS) {
      return await GptomAidlPluginIOS.closeBatchIOS(
        clientID: clientId,
        clientEmail: clientInfo?['email'],
        clientPhone: clientInfo?['phone'],
        preferableReceiptType: preferableReceiptType,
        printByPaymentApp: printByPaymentApp
      );
    }
    if (transactionIdAndroid == null) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'transactionIdAndroid is required for closeBatch',
      );
    }
    return await requestTransactionV2Android(
      transactionId: transactionIdAndroid,
      transactionType: TransactionType.closeBatch,
      redirectInfo: redirectInfo,
      clientInfo: clientInfo,
      openGptomUI: openGptomUI,
      preferableReceiptType: preferableReceiptType,
      printByPaymentApp: printByPaymentApp,
      clientId: clientId,
    );
  }

  // ---------------------------------------------------------------------------
  // 3) stateRequest
  // ---------------------------------------------------------------------------
  /// Fragt den aktuellen Status der Transaktion ab
  /// (IN_PROGRESS, COMPLETED, CANCELLED, ERROR etc.).
  Future<StateResult> stateRequestAndroid(String transactionId) {
    return GptomAidlPluginPlatform.instance.stateRequestAndroid(transactionId);
  }

  // ---------------------------------------------------------------------------
  // 4) TransactionInquire
  // ---------------------------------------------------------------------------
  /// Fragt nach Abschluss einer Transaktion die Details ab
  /// (z. B. maskierte Kartennummer, Betrag, Datum).
  Future<InquireResult> inquireTransactionAndroid(String transactionId) {
    return GptomAidlPluginPlatform.instance.inquireTransactionAndroid(transactionId);
  }

  // ---------------------------------------------------------------------------
  // Login-Service (AIDL 1.29.0, nur Android)
  // ---------------------------------------------------------------------------
  /// Bindet den GPTom-Login-Service. Muss vor [loginGpTom], [logoutGpTom]
  /// und [changeGpTomPassword] aufgerufen werden.
  Future<bool> bindLoginService({bool isDevAndroid = false}) {
    return GptomAidlPluginPlatform.instance.bindLoginService(isDevAndroid: isDevAndroid);
  }

  Future<void> unbindLoginService() {
    return GptomAidlPluginPlatform.instance.unbindLoginService();
  }

  /// Meldet den Benutzer in GP tom an. Das Ergebnis kommt asynchron über
  /// [loginStatusStream] (z. B. USER_LOGGED_IN, INVALID_CREDENTIALS, ...).
  Future<bool> loginGpTom({
    required String username,
    required String password,
    required String terminalId,
    String? authCode,
  }) {
    return GptomAidlPluginPlatform.instance.loginGpTom(
      username: username,
      password: password,
      terminalId: terminalId,
      authCode: authCode,
    );
  }

  /// Meldet den Benutzer in GP tom ab. Ergebnis über [loginStatusStream].
  Future<bool> logoutGpTom() {
    return GptomAidlPluginPlatform.instance.logoutGpTom();
  }

  /// Ändert das GP tom Passwort. Mit [validationOnly] = true wird das neue
  /// Passwort nur validiert. Ergebnis über [loginStatusStream]
  /// (PASSWORD_CHANGED, PASSWORD_CHANGE_FAILED, ...).
  Future<bool> changeGpTomPassword({
    required String currentPassword,
    required String newPassword,
    String? authCode,
    bool validationOnly = false,
  }) {
    return GptomAidlPluginPlatform.instance.changeGpTomPassword(
      currentPassword: currentPassword,
      newPassword: newPassword,
      authCode: authCode,
      validationOnly: validationOnly,
    );
  }

  /// Status-Updates aus der GP tom App (Login, Logout, Passwort-Änderung).
  Stream<GpTomLoginEvent> get loginStatusStream {
    return GptomAidlPluginPlatform.instance.loginStatusStream;
  }

  // ---------------------------------------------------------------------------
  // Info-Service (nur Android)
  // ---------------------------------------------------------------------------
  /// Bindet den GPTom-Info-Service. Muss vor [getGpTomInfo] aufgerufen werden.
  Future<bool> bindInfoService({bool isDevAndroid = false}) {
    return GptomAidlPluginPlatform.instance.bindInfoService(isDevAndroid: isDevAndroid);
  }

  Future<void> unbindInfoService() {
    return GptomAidlPluginPlatform.instance.unbindInfoService();
  }

  /// Liefert Infos über die GP tom App (Version, Login-Status, TID, MID, ...).
  Future<GpTomInfo?> getGpTomInfo() {
    return GptomAidlPluginPlatform.instance.getGpTomInfo();
  }

  /// Push-Updates der GP tom App-Infos (z. B. nach Login/Logout).
  Stream<GpTomInfo> get gpTomInfoStream {
    return GptomAidlPluginPlatform.instance.gpTomInfoStream;
  }
}
