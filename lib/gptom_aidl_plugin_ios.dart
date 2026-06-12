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
  static String _redirectUrl = 'xxx://redirect';

  static void listenForGptomRedirectsIOS(String uriScheme) {
    _redirectUrl = '$uriScheme://redirect';
    if (_isListening) return;

    try {
      _appLinks = AppLinks();
      _appLinks.uriLinkStream.listen((Uri uri) {
        if (uri.scheme == uriScheme) {
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

    final success = await launchUrl(uri);

    if (!success) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'Konnte GPTom nicht öffnen',
      );
    }

    try {
      final redirectedUri = await gptomRedirectStream.stream.first.timeout(Duration(seconds: 15));

      final query = redirectedUri.queryParameters as Map<String, dynamic>;
      return Batch.fromQuery(query['batch']);
    } catch (e) {
      throw Exception(
        'Kein Redirect erhalten oder Timeout, error: $e',
      );
    }
  }

  static Future<RequestResult> createTransactionIOS({
    required double amount,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    double? tipAmount,
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
        'amount': (amount * 100).toInt().toString(),
        if (clientID != null) 'clientID': clientID,
        if (originReferenceNum != null) 'originReferenceNum': originReferenceNum,
        'redirectUrl': _redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.key,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
        if (tipAmount != null) 'tipAmount': (tipAmount * 100).toInt().toString(),
        'tipCollect': tipCollect.toString(),
        'transactionType': transactionMethode.text,
      },
    );

    final success = await launchUrl(uri);

    if (!success) {
      return RequestResult(result: -1002, responseMessage: 'Konnte GPTom nicht öffnen');
    }

    try {
      final redirectedUri = await gptomRedirectStream.stream.first.timeout(Duration(seconds: 60));

      final query = redirectedUri.queryParameters;
      final receiptRaw = query['receipt'];

      if (receiptRaw == null) {
        return RequestResult(result: -1004, responseMessage: 'Kein Receipt enthalten');
      }

      final receipt = jsonDecode(receiptRaw);
      print(receipt);

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
        amount: double.tryParse(receipt['amount']??''),
        tipAmount: double.tryParse(receipt['tipAmount']??''),
        totalAmount: double.tryParse(receipt['totalAmount']??''),
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

    final success = await launchUrl(uri);

    if (!success) {
      return RequestResult(result: -1002, responseMessage: 'Konnte GPTom nicht öffnen');
    }

    try {
      final redirectedUri = await gptomRedirectStream.stream.first.timeout(Duration(seconds: 60));
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
        amount: double.tryParse(receipt['amount'] ?? ''),
        totalAmount: double.tryParse(receipt['totalAmount'] ?? ''),
        tipAmount: double.tryParse(receipt['tipAmount'] ?? ''),
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