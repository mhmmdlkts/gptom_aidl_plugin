import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gptom_aidl_plugin/models/batch.dart';
import 'package:url_launcher/url_launcher.dart';
import 'enums/preferable_receipt_type.dart';
import 'enums/transaction_methode.dart';
import 'enums/transaction_type.dart';
import 'models/request_result.dart';

class GptomAidlPluginIOS {

  static final StreamController<Uri> gptomRedirectStream = StreamController<Uri>.broadcast();
  static late final AppLinks _appLinks;
  static bool _isListening = false;
  static String _expectedScheme = '';
  static String _redirectUrl = 'xxx://redirect';

  static void listenForGptomRedirectsIOS(String uriScheme) {
    // Scheme als Feld halten, damit der Filter auch bei einem späteren
    // Aufruf mit anderem Scheme zur Redirect-URL passt.
    _expectedScheme = uriScheme;
    _redirectUrl = '$uriScheme://redirect';
    if (_isListening) return;

    try {
      _appLinks = AppLinks();
      _appLinks.uriLinkStream.listen((Uri uri) {
        if (uri.scheme == _expectedScheme) {
          gptomRedirectStream.add(uri);
        }
      }, onError: (e) {
        debugPrint('GptomAidlPlugin: Fehler beim Lauschen auf Redirects: $e');
      });

      _isListening = true;
    } catch (e) {
      debugPrint('GptomAidlPlugin: Fehler bei Initialisierung von AppLinks: $e');
    }
  }

  /// Standard-Timeouts für den Redirect aus GP tom zurück in die App.
  static const Duration defaultTransactionRedirectTimeout = Duration(seconds: 60);
  static const Duration defaultCloseBatchRedirectTimeout = Duration(seconds: 15);

  /// Baut die URL für gptom://batch/close (Werte laut iOS-URL-Scheme-Doku).
  @visibleForTesting
  static Uri buildCloseBatchUri({
    required String redirectUrl,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
  }) {
    return Uri(
      scheme: 'gptom',
      host: 'batch',
      path: 'close',
      queryParameters: {
        if (clientID != null) 'clientID': clientID,
        'redirectUrl': redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.iosKey,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
      },
    );
  }

  static Future<Batch> closeBatchIOS({
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    Duration? redirectTimeout,
  }) async {
    if (!Platform.isIOS) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'closeBatchIOS is not supported on Android',
      );
    }

    final uri = buildCloseBatchUri(
      redirectUrl: _redirectUrl,
      clientID: clientID,
      printByPaymentApp: printByPaymentApp,
      preferableReceiptType: preferableReceiptType,
      clientPhone: clientPhone,
      clientEmail: clientEmail,
    );

    // Vor dem Öffnen abonnieren, damit kein Redirect verpasst wird.
    final redirectFuture = gptomRedirectStream.stream.first
        .timeout(redirectTimeout ?? defaultCloseBatchRedirectTimeout);

    final success = await launchUrl(uri);

    if (!success) {
      redirectFuture.ignore();
      throw PlatformException(
        code: 'PlatformError',
        message: 'Konnte GPTom nicht öffnen',
      );
    }

    try {
      final redirectedUri = await redirectFuture;
      return batchFromRedirect(redirectedUri);
    } catch (e) {
      throw Exception(
        'Kein Redirect erhalten oder Timeout, error: $e',
      );
    }
  }

  /// Parst den Batch aus dem Redirect von gptom://batch/close.
  @visibleForTesting
  static Batch batchFromRedirect(Uri redirectedUri) {
    final batchRaw = redirectedUri.queryParameters['batch'];
    if (batchRaw == null) {
      throw Exception('Kein Batch im Redirect enthalten');
    }
    return Batch.fromQuery(batchRaw);
  }

  /// Status-Wert, mit dem GP tom im Redirect einen erfolgreichen Abschluss
  /// meldet (query["status"]). Wird nur gebraucht, wenn KEIN `receipt` im
  /// Redirect steckt – dann ist der Status die einzige verlässliche
  /// Information darüber, ob die Karte belastet wurde. Bewusst nur der
  /// eindeutig belegte Wert: ein falsch als Erfolg gewerteter Status würde
  /// eine nicht kassierte Zahlung als Beleg aufzeichnen.
  static const Set<String> _completedStatuses = {'COMPLETED'};

  static bool _statusIsCompleted(String? status) =>
      status != null && _completedStatuses.contains(status.toUpperCase());

  /// Receipt-Beträge liefert GPTom als Euro-Dezimalwerte (z. B. "4.35").
  static int? _centsFromReceipt(dynamic value) {
    if (value == null) return null;
    final parsed = double.tryParse(value.toString());
    if (parsed == null) return null;
    return (parsed * 100).round();
  }

  /// Baut die URL für gptom://transaction/create (Sale).
  @visibleForTesting
  static Uri buildCreateTransactionUri({
    required int amountCents,
    required String redirectUrl,
    required TransactionMethode transactionMethode,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    int? tipAmountCents,
    bool tipCollect = false,
  }) {
    return Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'create',
      queryParameters: {
        // GPTom erwartet den Betrag in Cent (*100-Format)
        'amount': amountCents.toString(),
        if (clientID != null) 'clientID': clientID,
        if (originReferenceNum != null) 'originReferenceNum': originReferenceNum,
        'redirectUrl': redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.iosKey,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
        if (tipAmountCents != null) 'tipAmount': tipAmountCents.toString(),
        'tipCollect': tipCollect.toString(),
        'transactionType': transactionMethode.text,
      },
    );
  }

  /// Baut die URL für gptom://transaction/cancel (Void).
  @visibleForTesting
  static Uri buildCancelTransactionUri({
    required String amsID,
    required String redirectUrl,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
  }) {
    return Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'cancel',
      queryParameters: {
        'amsID': amsID,
        if (clientID != null) 'clientID': clientID,
        'redirectUrl': redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.iosKey,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
      },
    );
  }

  /// Gemeinsames Receipt-Parsing für create/cancel-Redirects.
  /// Bei create ist die "eigene" Transaktions-ID die amsID, bei cancel die
  /// transactionID (und die amsID landet in externalTransactionID).
  static RequestResult _requestResultFromReceipt(
    Uri redirectedUri, {
    required bool printByPaymentApp,
    required bool isCancel,
  }) {
    final query = redirectedUri.queryParameters;
    final receiptRaw = query['receipt'];
    final status = query['status'];

    if (receiptRaw == null) {
      // GP tom liefert bei erfolgreichem Abschluss gelegentlich keinen
      // `receipt`-Parameter, meldet den Erfolg aber über `status`
      // (z. B. "COMPLETED"). Diesen Fall NICHT als -1004 verwerfen – sonst
      // gilt eine tatsächlich belastete Karte als abgebrochen und der Umsatz
      // fehlt in der Aufzeichnung. Ohne Beleg fehlen die Kartendetails
      // (amsID, Betrag) – der Abschluss selbst ist aber verlässlich.
      if (_statusIsCompleted(status)) {
        return RequestResult(
          result: 0,
          responseMessage: status,
          amsID: query['amsID'],
          transactionId: query['amsID'],
          externalTransactionID: query['transactionID'],
          printByPaymentApp: printByPaymentApp,
          transactionType:
              isCancel ? TransactionType.voidSell : TransactionType.sell,
        );
      }
      // Kein Beleg und kein Erfolgs-Status → unklar/kein Abschluss. Den
      // Status durchreichen, damit die App den echten Grund sieht.
      return RequestResult(
        result: -1004,
        responseMessage: status ?? 'Kein Receipt enthalten',
      );
    }

    final receipt = jsonDecode(receiptRaw);

    String cardNumber = receipt['cardNumber'] ?? '';
    if (cardNumber.length == 4) {
      cardNumber = '**** **** **** $cardNumber';
    }
    String? date, time;

    if (receipt['date'] != null) {
      final dateTime = DateTime.parse(receipt['date']);
      date = '${dateTime.day.toString().padLeft(2, '0')}${dateTime.month.toString().padLeft(2, '0')}${dateTime.year.toString().substring(2)}';
      time = '${dateTime.hour.toString().padLeft(2, '0')}${dateTime.minute.toString().padLeft(2, '0')}${dateTime.second.toString().padLeft(2, '0')}';
    }

    return RequestResult(
      result: receipt['result'],
      transactionId: isCancel ? receipt['transactionID'] : receipt['amsID'],
      amountCents: _centsFromReceipt(receipt['amount']),
      tipAmountCents: _centsFromReceipt(receipt['tipAmount']),
      totalAmountCents: _centsFromReceipt(receipt['totalAmount']),
      batchNumber: receipt['batchNumber'],
      approvedCode: receipt['authorizationCode'],
      emvAppLable: receipt['emvAppLabel'],
      emvAid: receipt['emvAid'],
      responseMessage: query['status'],
      sequenceNumber: receipt['sequenceNumber'],
      terminalID: receipt['terminalID'],
      cardNumber: cardNumber,
      cardProduct: receipt['cardType'],
      currencyCode: receipt['currencyCode'],
      pinOk: receipt['pinOk'] == true,
      printByPaymentApp: printByPaymentApp,
      externalTransactionID: isCancel ? receipt['amsID'] : receipt['transactionID'],
      date: date,
      cardDataEntry: receipt['cardEntryMode'],
      amsID: receipt['amsID'],
      time: time,
      transactionType: isCancel ? TransactionType.voidSell : TransactionType.sell,
    );
  }

  /// Parst das Ergebnis aus dem Redirect von gptom://transaction/create.
  @visibleForTesting
  static RequestResult requestResultFromCreateRedirect(
    Uri redirectedUri, {
    required bool printByPaymentApp,
  }) {
    return _requestResultFromReceipt(
      redirectedUri,
      printByPaymentApp: printByPaymentApp,
      isCancel: false,
    );
  }

  /// Parst das Ergebnis aus dem Redirect von gptom://transaction/cancel.
  @visibleForTesting
  static RequestResult requestResultFromCancelRedirect(
    Uri redirectedUri, {
    required bool printByPaymentApp,
  }) {
    return _requestResultFromReceipt(
      redirectedUri,
      printByPaymentApp: printByPaymentApp,
      isCancel: true,
    );
  }

  static Future<RequestResult> createTransactionIOS({
    required int amountCents,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    int? tipAmountCents,
    bool tipCollect = false,
    required TransactionMethode transactionMethode,
    Duration? redirectTimeout,
  }) async {
    if (!Platform.isIOS) {
      return RequestResult.exception();
    }
    final uri = buildCreateTransactionUri(
      amountCents: amountCents,
      redirectUrl: _redirectUrl,
      transactionMethode: transactionMethode,
      originReferenceNum: originReferenceNum,
      clientID: clientID,
      printByPaymentApp: printByPaymentApp,
      preferableReceiptType: preferableReceiptType,
      clientPhone: clientPhone,
      clientEmail: clientEmail,
      tipAmountCents: tipAmountCents,
      tipCollect: tipCollect,
    );

    // Vor dem Öffnen abonnieren, damit kein Redirect verpasst wird.
    final redirectFuture = gptomRedirectStream.stream.first
        .timeout(redirectTimeout ?? defaultTransactionRedirectTimeout);

    final success = await launchUrl(uri);

    if (!success) {
      redirectFuture.ignore();
      return RequestResult(result: -1002, responseMessage: 'Konnte GPTom nicht öffnen');
    }

    try {
      final redirectedUri = await redirectFuture;
      return requestResultFromCreateRedirect(
        redirectedUri,
        printByPaymentApp: printByPaymentApp,
      );
    } catch (e) {
      return RequestResult(result: -1003, responseMessage: 'Kein Redirect erhalten oder Timeout');
    }
  }

  static Future<RequestResult> cancelTransactionIOS({
    required String amsID,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    Duration? redirectTimeout,
  }) async {
    if (!Platform.isIOS) {
      return RequestResult.exception();
    }

    final uri = buildCancelTransactionUri(
      amsID: amsID,
      redirectUrl: _redirectUrl,
      clientID: clientID,
      printByPaymentApp: printByPaymentApp,
      preferableReceiptType: preferableReceiptType,
      clientPhone: clientPhone,
      clientEmail: clientEmail,
    );

    // Vor dem Öffnen abonnieren, damit kein Redirect verpasst wird.
    final redirectFuture = gptomRedirectStream.stream.first
        .timeout(redirectTimeout ?? defaultTransactionRedirectTimeout);

    final success = await launchUrl(uri);

    if (!success) {
      redirectFuture.ignore();
      return RequestResult(result: -1002, responseMessage: 'Konnte GPTom nicht öffnen');
    }

    try {
      final redirectedUri = await redirectFuture;
      return requestResultFromCancelRedirect(
        redirectedUri,
        printByPaymentApp: printByPaymentApp,
      );
    } catch (e) {
      return RequestResult(result: -1003, responseMessage: 'Kein Redirect erhalten oder Timeout');
    }
  }
}
