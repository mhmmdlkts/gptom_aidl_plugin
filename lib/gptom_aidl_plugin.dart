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
///   ruft das jeweilige PlatformInterface auf und gibt das geparste
///   Ergebnis-Modell zurück (z. B. `RequestResult`, `StateResult`).
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
  /// - [amountCents]: in Cent (1111 => 11,11 EUR), wie es GPTom erwartet
  /// - [tipAmountCents] (optional)
  /// - [originTransactionId] (bei VOID/REFUND)
  /// - [cancelMode]: 1= letzte Transaktion, 2=ältere Transaktionen (ggf. optional)
  /// - [clientId]: falls nötig
  /// - [printByPaymentApp], [tipCollect], [redirectPackageName], [redirectInfo], ...
  Future<RequestResult> requestTransactionV2Android({
    required String transactionId,
    required TransactionType transactionType,
    int? amountCents,
    int? tipAmountCents,
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
    if (amountCents != null) _requireNonNegativeCents('amountCents', amountCents);
    if (tipAmountCents != null) _requireNonNegativeCents('tipAmountCents', tipAmountCents);
    final params = <String, dynamic>{
      'transactionID': transactionId,
      'transactionType': transactionType.id,
      if (amountCents != null) 'amount': amountCents,
      'openGptomUI': openGptomUI,
      if (tipAmountCents != null) 'tipAmount': tipAmountCents,
      if (originTransactionId != null) 'originTransactionID': originTransactionId,
      if (cancelMode != null) 'cancelMode': cancelMode.id,
      if (clientId != null) 'clientID': clientId,
      if (printByPaymentApp != null) 'printByPaymentApp': printByPaymentApp,
      if (tipCollect != null) 'tipCollect': tipCollect,
      if (redirectInfo != null) 'redirectInfo': redirectInfo,
      if (clientInfo != null) 'clientInfo': normalizeClientInfo(clientInfo),
      if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.aidlKey,
    };
    // Dann rufen wir das platform interface auf
    return GptomAidlPluginPlatform.instance.requestTransactionV2Android(params);
  }

  static void _requirePositiveCents(String name, int value) {
    if (value <= 0) {
      throw ArgumentError.value(value, name, 'muss > 0 sein (Betrag in Cent)');
    }
  }

  static void _requireNonNegativeCents(String name, int value) {
    if (value < 0) {
      throw ArgumentError.value(value, name, 'darf nicht negativ sein (Cent)');
    }
  }

  /// GP tom erwartet clientInfo als {"contact":{"email":...,"phone":...}}
  /// (ClientInfoEntity -> UserContactEntity in der AIDL-Bibliothek). Flache
  /// Maps ({email, phone}) werden deshalb in die contact-Struktur gehoben;
  /// eine bereits verschachtelte Map bleibt unverändert.
  static Map<String, dynamic> normalizeClientInfo(Map<String, dynamic> clientInfo) {
    final contact = <String, dynamic>{
      if (clientInfo['contact'] is Map)
        ...Map<String, dynamic>.from(clientInfo['contact'] as Map),
      if (clientInfo['email'] != null) 'email': clientInfo['email'],
      if (clientInfo['phone'] != null) 'phone': clientInfo['phone'],
    };
    final rest = Map<String, dynamic>.from(clientInfo)
      ..remove('contact')
      ..remove('email')
      ..remove('phone');
    return {
      ...rest,
      if (contact.isNotEmpty) 'contact': contact,
    };
  }


  /// Verkauf. [amountCents] und [tipAmountCents] in Cent (1111 => 11,11 EUR).
  ///
  /// [redirectTimeoutIOS] begrenzt auf iOS das Warten auf den Redirect aus
  /// GP tom (Standard: 60 Sekunden).
  Future<RequestResult> sell({
    String? transactionIdAndroid,
    required int amountCents,
    required TransactionMethode transactionMethode,
    int tipAmountCents = 0,
    String? clientId,
    bool printByPaymentApp = false,
    bool tipCollect = false,
    bool openGptomUI = true,
    Map<String, dynamic>? redirectInfo,
    Map<String, dynamic>? clientInfo,
    PreferableReceiptType? preferableReceiptType,
    Duration? redirectTimeoutIOS,
  }) async {
    _requirePositiveCents('amountCents', amountCents);
    _requireNonNegativeCents('tipAmountCents', tipAmountCents);
    if (Platform.isIOS) {
      return await GptomAidlPluginIOS.createTransactionIOS(
        amountCents: amountCents,
        transactionMethode: transactionMethode,
        tipCollect: tipCollect,
        tipAmountCents: tipAmountCents,
        printByPaymentApp: printByPaymentApp,
        clientID: clientId,
        preferableReceiptType: preferableReceiptType,
        clientEmail: clientInfo?['email'],
        clientPhone: clientInfo?['phone'],
        redirectTimeout: redirectTimeoutIOS,
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
      amountCents: amountCents,
      tipAmountCents: tipAmountCents,
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
    Duration? redirectTimeoutIOS,
  }) async {
    if (Platform.isIOS) {
      return await GptomAidlPluginIOS.cancelTransactionIOS(
        amsID: originTransactionId,
        preferableReceiptType: preferableReceiptType,
        clientPhone: clientInfo?['phone'],
        clientEmail: clientInfo?['email'],
        clientID: clientId,
        redirectTimeout: redirectTimeoutIOS,
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
  /// Transaktion. [amountCents] in Cent. Nur Android – auf iOS bietet das
  /// GPTom-URL-Scheme dafür keinen Weg.
  Future<RequestResult> refund({
    String? transactionIdAndroid,
    required String originTransactionId,
    required int amountCents,
    String? clientId,
    bool printByPaymentApp = false,
    Map<String, dynamic>? redirectInfo,
    Map<String, dynamic>? clientInfo,
    bool openGptomUI = true,
    PreferableReceiptType? preferableReceiptType,
  }) async {
    _requirePositiveCents('amountCents', amountCents);
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
      amountCents: amountCents,
      clientId: clientId,
      printByPaymentApp: printByPaymentApp,
      redirectInfo: redirectInfo,
      clientInfo: clientInfo,
      openGptomUI: openGptomUI,
      preferableReceiptType: preferableReceiptType,
    );
  }

  /// Kassenschnitt. Liefert auf Android ein [RequestResult], auf iOS einen
  /// [Batch] (GP tom stellt dort nur die Batch-Daten im Redirect bereit).
  Future<Object?> closeBatch({
    String? transactionIdAndroid,
    String? clientId,
    Map<String, dynamic>? redirectInfo,
    Map<String, dynamic>? clientInfo,
    bool openGptomUI = true,
    PreferableReceiptType? preferableReceiptType,
    bool printByPaymentApp = false,
    Duration? redirectTimeoutIOS,
  }) async {
    if (Platform.isIOS) {
      return await GptomAidlPluginIOS.closeBatchIOS(
        clientID: clientId,
        clientEmail: clientInfo?['email'],
        clientPhone: clientInfo?['phone'],
        preferableReceiptType: preferableReceiptType,
        printByPaymentApp: printByPaymentApp,
        redirectTimeout: redirectTimeoutIOS,
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
