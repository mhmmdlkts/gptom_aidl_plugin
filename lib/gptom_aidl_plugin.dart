import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';
import 'package:gptom_aidl_plugin/models/inquire_result.dart';
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
  // Beispiel: Bind Service (bereits vorhanden)
  // ---------------------------------------------------------------------------
  Future<bool> bindService({bool isDevAndroid = false, String uriSchemeIOS = 'xxx'}) async {
    print('aaa');
    if (Platform.isIOS) {
      GptomAidlPluginIOS.listenForGptomRedirectsIOS(uriSchemeIOS);
      return Future.value(true);
    }
    return GptomAidlPluginPlatform.instance.bindService(isDevAndroid: isDevAndroid);
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
  /// - [amount]: in *100-Format (z.B. 1111 => 11.11 EUR)
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
      if (amount != null) 'amount': (amount * 100).toInt(),
      'openGptomUI': openGptomUI,
      if (tipAmount != null) 'tipAmount': (tipAmount * 100).toInt(),
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
      await GptomAidlPluginIOS.closeBatchIOS(
        clientID: clientId,
        clientEmail: clientInfo?['email'],
        clientPhone: clientInfo?['phone'],
        preferableReceiptType: preferableReceiptType,
        printByPaymentApp: printByPaymentApp
      );
      return;
    }
    if (transactionIdAndroid == null) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'transactionIdAndroid is required for closeBatch',
      );
    }
    RequestResult res = await requestTransactionV2Android(
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
}