import 'dart:convert';

import '../enums/transaction_type.dart';

/// Dart-Klasse für das Ergebnis einer TransactionInquire-Anfrage.
/// Dabei können sowohl Erfolgs- als auch Fehler-Felder auftreten.
class InquireResult {
  /// z. B. 0 = Erfolg, -1 = Fehler, -6 etc.
  final int result;

  /// transactionId (aus dem Register / Request)
  final String transactionId;

  /// approvedCode: z. B. "529625" bei Erfolg
  final String? approvedCode;

  /// merchantID: z. B. "000007311211351"
  final String? merchantID;

  /// terminalID: z. B. "11263520"
  final String? terminalID;

  /// amount = *100 Format (z. B. 1111 => 11,11)
  final double amount;

  /// tipAmount = *100 Format
  final double tipAmount;

  /// currencyCode: z. B. EUR
  final String? currencyCode;

  /// cardNumber = "**** **** **** 7866"
  final String? cardNumber;

  /// cardDataEntry = "CONTACTLESS", "ICC", "MAG", ...
  final String? cardDataEntry;

  /// cardProduct = "VISA", "MASTER", ...
  final String? cardProduct;

  /// responseMessage = "APPROVED", "DECLINED", ...
  final String? responseMessage;

  /// date und time z. B. "250117", "121032"
  final String? date;
  final String? time;

  /// emvAid, emvAppLable, externalTransactionID
  final String? emvAid;
  final String? emvAppLable;
  final String? externalTransactionID;

  /// batchNumber
  final String? batchNumber;

  /// printByPaymentApp: true/false
  final bool? printByPaymentApp;

  /// pinOk: z. B. false
  final bool? pinOk;

  /// transactionType: 1=Sale, 2=Void, ...
  final TransactionType? transactionType;

  // sequenceNumber
  final String? sequenceNumber;

  /// Ein verschachteltes MerchantInfo-Objekt
  final InquireMerchantInfo? merchantInfo;

  /// Fehler-Objekt, falls result != 0
  final InquireErrorInfo? error;

  InquireResult({
    required this.result,
    required this.transactionId,
    required this.amount,
    required this.tipAmount,
    this.approvedCode,
    this.merchantID,
    this.terminalID,
    this.currencyCode,
    this.cardNumber,
    this.cardDataEntry,
    this.cardProduct,
    this.responseMessage,
    this.date,
    this.time,
    this.emvAid,
    this.emvAppLable,
    this.externalTransactionID,
    this.batchNumber,
    this.printByPaymentApp,
    this.pinOk,
    this.transactionType,
    this.sequenceNumber,
    this.merchantInfo,
    this.error,
  });

  /// Parse aus einer Map (z. B. wenn Native Plugin bereits Map liefert).
  factory InquireResult.fromMap(Map<String, dynamic> map) {
    return InquireResult(
      // result ist in deinen Beispielen immer da => required
      result: map['result'] is int
          ? (map['result'] as int)
          : int.tryParse('${map['result']}') ?? -999,

      // transactionID kann "..." sein oder leer.
      // Wir machen sie hier required, also fallback, falls gar nicht existiert.
      transactionId: map['trasanctionID'] as String,
      approvedCode: map['approvedCode'] as String?,
      merchantID: map['merchantID'] as String?,
      terminalID: map['terminalID'] as String?,
      amount: map['amount'] is num ? (map['amount'] + 0.0) : int.parse((map['amount'] as String?)??'0')/100,
      tipAmount: map['tipAmount'] is num ? (map['tipAmount'] + 0.0) : int.parse((map['tipAmount'] as String?)??'0')/100,
      currencyCode: map['currencyCode'] as String?,
      cardNumber: map['cardNumber'] as String?,
      cardDataEntry: map['cardDataEntry'] as String?,
      cardProduct: map['cardProduct'] as String?,
      responseMessage: map['responseMessage'] as String?,
      date: map['date'] as String?,
      time: map['time'] as String?,
      emvAid: map['emvAid'] as String?,
      emvAppLable: map['emvAppLable'] as String?,
      externalTransactionID: map['externalTransactionID'] as String?,
      batchNumber: map['batchNumber'] as String?,
      printByPaymentApp: map['printByPaymentApp'] as bool?,
      pinOk: map['pinOk'] as bool?,
      transactionType: map['transacitonType'] is int ? TransactionType.values.where((element) => element.id == map['transacitonType']).firstOrNull : null,
      sequenceNumber: map['sequenceNumber'] as String?,

      merchantInfo: map['merchantInfo'] != null
          ? InquireMerchantInfo.fromMap(
        Map<String, dynamic>.from(map['merchantInfo']),
      )
          : null,

      error: map['error'] != null
          ? InquireErrorInfo.fromMap(
        Map<String, dynamic>.from(map['error']),
      )
          : null,
    );
  }

  factory InquireResult.exception() {
    return InquireResult(
      result: -1001,
      transactionId: '',
      amount: 0,
      tipAmount: 0,
    );
  }

  /// Parse aus JSON-String (z. B. wenn dein natives Plugin einen String zurückgibt).
  factory InquireResult.fromJson(String jsonStr) {
    final dynamic decoded = jsonDecode(jsonStr);
    if (decoded is Map<String, dynamic>) {
      return InquireResult.fromMap(decoded);
    } else {
      throw FormatException('InquireResult: JSON was not Map<String,dynamic>');
    }
  }

  Map<String, dynamic> toMap() {
    return {
      'result': result,
      'trasanctionID': transactionId,
      'approvedCode': approvedCode,
      'merchantID': merchantID,
      'terminalID': terminalID,
      'amount': amount,
      'tipAmount': tipAmount,
      'currencyCode': currencyCode,
      'cardNumber': cardNumber,
      'cardDataEntry': cardDataEntry,
      'cardProduct': cardProduct,
      'responseMessage': responseMessage,
      'date': date,
      'time': time,
      'emvAid': emvAid,
      'emvAppLable': emvAppLable,
      'externalTransactionID': externalTransactionID,
      'batchNumber': batchNumber,
      'printByPaymentApp': printByPaymentApp,
      'pinOk': pinOk,
      'transacitonType': transactionType?.id,
      'sequenceNumber': sequenceNumber,
    };
  }
}

/// Verschachtelte Info, z. B. {"city":"Bratislava","company":"Airspeed SK s.r.o.","house":"100/B","street":"Vajnorská","zip":"83104"}
class InquireMerchantInfo {
  final String? city;
  final String? company;
  final String? house;
  final String? street;
  final String? zip;

  InquireMerchantInfo({
    this.city,
    this.company,
    this.house,
    this.street,
    this.zip,
  });

  factory InquireMerchantInfo.fromMap(Map<String, dynamic> map) {
    return InquireMerchantInfo(
      city: map['city'] as String?,
      company: map['company'] as String?,
      house: map['house'] as String?,
      street: map['street'] as String?,
      zip: map['zip'] as String?,
    );
  }

  @override
  String toString() {
    return 'InquireMerchantInfo(city=$city, company=$company, house=$house, street=$street, zip=$zip)';
  }
}

/// Falls "error" existiert: {"errorCode":"1-038","exception":"XYZException...","supportID":"Ca38A8"}
class InquireErrorInfo {
  final String? errorCode;
  final String? exception;
  final String? supportID;

  InquireErrorInfo({this.errorCode, this.exception, this.supportID});

  factory InquireErrorInfo.fromMap(Map<String, dynamic> map) {
    return InquireErrorInfo(
      errorCode: map['errorCode'] as String?,
      exception: map['exception'] as String?,
      supportID: map['supportID'] as String?,
    );
  }

  @override
  String toString() {
    return 'InquireErrorInfo(errorCode=$errorCode, exception=$exception, supportID=$supportID)';
  }
}