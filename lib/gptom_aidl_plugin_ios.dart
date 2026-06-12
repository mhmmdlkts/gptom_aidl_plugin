import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:app_links/app_links.dart';
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
        print('Fehler beim Lauschen auf Redirects: $e');
      });

      _isListening = true;
    } catch (e) {
      print('Fehler bei Initialisierung von AppLinks: $e');
    }
  }

  static Future<Batch> closeBatchIOS({
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
  }) async {
    if (!Platform.isIOS) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'closeBatchIOS is not supported on Android',
      );
    }

    final uri = Uri(
      scheme: 'gptom',
      host: 'batch',
      path: 'close',
      queryParameters: {
        if (clientID != null) 'clientID': clientID,
        'redirectUrl': _redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.key,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
      },
    );

    // Vor dem Öffnen abonnieren, damit kein Redirect verpasst wird.
    final redirectFuture =
        gptomRedirectStream.stream.first.timeout(Duration(seconds: 15));

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

      final query = redirectedUri.queryParameters;
      final batchRaw = query['batch'];
      if (batchRaw == null) {
        throw Exception('Kein Batch im Redirect enthalten');
      }
      return Batch.fromQuery(batchRaw);
    } catch (e) {
      throw Exception(
        'Kein Redirect erhalten oder Timeout, error: $e',
      );
    }
  }

  /// Receipt-Beträge liefert GPTom als Euro-Dezimalwerte (z. B. "4.35").
  static int? _centsFromReceipt(dynamic value) {
    if (value == null) return null;
    final parsed = double.tryParse(value.toString());
    if (parsed == null) return null;
    return (parsed * 100).round();
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
  }) async {
    if (!Platform.isIOS) {
      return RequestResult.exception();
    }
    final uri = Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'create',
      queryParameters: {
        // GPTom erwartet den Betrag in Cent (*100-Format)
        'amount': amountCents.toString(),
        if (clientID != null) 'clientID': clientID,
        if (originReferenceNum != null) 'originReferenceNum': originReferenceNum,
        'redirectUrl': _redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.key,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
        if (tipAmountCents != null) 'tipAmount': tipAmountCents.toString(),
        'tipCollect': tipCollect.toString(),
        'transactionType': transactionMethode.text,
      },
    );

    // Vor dem Öffnen abonnieren, damit kein Redirect verpasst wird.
    final redirectFuture =
        gptomRedirectStream.stream.first.timeout(Duration(seconds: 60));

    final success = await launchUrl(uri);

    if (!success) {
      redirectFuture.ignore();
      return RequestResult(result: -1002, responseMessage: 'Konnte GPTom nicht öffnen');
    }

    try {
      final redirectedUri = await redirectFuture;

      final query = redirectedUri.queryParameters;
      final receiptRaw = query['receipt'];

      if (receiptRaw == null) {
        return RequestResult(result: -1004, responseMessage: 'Kein Receipt enthalten');
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
        transactionId: receipt['amsID'],
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
        externalTransactionID: receipt['transactionID'],
        date: date,
        cardDataEntry: receipt['cardEntryMode'],
        amsID: receipt['amsID'],
        time: time,
        transactionType: TransactionType.sell
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
  }) async {
    if (!Platform.isIOS) {
      return RequestResult.exception();
    }

    final uri = Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'cancel',
      queryParameters: {
        'amsID': amsID,
        if (clientID != null) 'clientID': clientID,
        'redirectUrl': _redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.key,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
      },
    );

    // Vor dem Öffnen abonnieren, damit kein Redirect verpasst wird.
    final redirectFuture =
        gptomRedirectStream.stream.first.timeout(Duration(seconds: 60));

    final success = await launchUrl(uri);

    if (!success) {
      redirectFuture.ignore();
      return RequestResult(result: -1002, responseMessage: 'Konnte GPTom nicht öffnen');
    }

    try {
      final redirectedUri = await redirectFuture;
      final query = redirectedUri.queryParameters;
      final receiptRaw = query['receipt'];

      if (receiptRaw == null) {
        return RequestResult(result: -1004, responseMessage: 'Kein Receipt enthalten');
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
        transactionId: receipt['transactionID'],
        amountCents: _centsFromReceipt(receipt['amount']),
        totalAmountCents: _centsFromReceipt(receipt['totalAmount']),
        tipAmountCents: _centsFromReceipt(receipt['tipAmount']),
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
        externalTransactionID: receipt['amsID'],
        date: date,
        cardDataEntry: receipt['cardEntryMode'],
        amsID: receipt['amsID'],
        time: time,
        transactionType: TransactionType.voidSell,
      );
    } catch (e) {
      return RequestResult(result: -1003, responseMessage: 'Kein Redirect erhalten oder Timeout');
    }
  }

}