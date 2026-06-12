import 'dart:convert';

import 'package:gptom_aidl_plugin/enums/transaction_type.dart';

// cardType
// transactionType -> anders
// AutorisierungCode, CODE
/// Dart-Klasse, die das Ergebnis (Response) von transactionRequestV2 widerspiegelt.
/// Sie berücksichtigt Erfolg (result=0) und Fehler (result != 0).
class RequestResult { 
  final int? result;          // z. B. 0 = success, -1 = fail, -6 = Invalid params ...
  final String? amsID;
  final String? transactionId;
  final int? amountCents;       // in Cent (1111 => 11,11 EUR)
  final int? tipAmountCents;    // in Cent
  final int? totalAmountCents;  // in Cent
  final String? approvedCode; // bei Erfolg
  final String? batchNumber;
  final String? cardNumber;   // maskiert z. B. "**** **** **** 7866"
  final String? cardDataEntry;
  final String? cardProduct;
  final String? currencyCode;    // z. B. 978
  final String? date;         // "250117"
  final String? time;         // "121032"
  final String? emvAid;
  final String? emvAppLable;
  final String? externalTransactionID;
  final String? merchantID;
  final MerchantInfo? merchantInfo; // Verschachtelte Klasse (s. u.)
  final bool? pinOk;
  final bool? printByPaymentApp;
  final String? responseMessage; // z. B. "APPROVED"
  final TransactionType? transactionType;     // 1,2,4
  final String? sequenceNumber;
  final String? terminalID;

  // Felder für Fehler:
  final ErrorInfo? error;         // z. B. {"errorCode":"1-097",...}

  // evtl. originTransactionID, tipCollect, etc., falls sie kommen

  /// Komfort-Getter für Anzeigen in Euro.
  double? get amountEuro => amountCents == null ? null : amountCents! / 100;
  double? get tipAmountEuro => tipAmountCents == null ? null : tipAmountCents! / 100;
  double? get totalAmountEuro => totalAmountCents == null ? null : totalAmountCents! / 100;

  RequestResult({
    this.result,
    this.amsID,
    this.transactionId,
    this.amountCents,
    this.tipAmountCents,
    this.totalAmountCents,
    this.approvedCode,
    this.batchNumber,
    this.cardNumber,
    this.cardDataEntry,
    this.cardProduct,
    this.currencyCode,
    this.date,
    this.time,
    this.emvAid,
    this.emvAppLable,
    this.externalTransactionID,
    this.merchantID,
    this.merchantInfo,
    this.pinOk,
    this.printByPaymentApp,
    this.responseMessage,
    this.transactionType,
    this.sequenceNumber,
    this.terminalID,
    this.error,
  });

  /// Aus einer Map (falls dein Native Plugin eine Map zurückgibt)
  factory RequestResult.fromMap(Map<String, dynamic> map) {
    return RequestResult(
      result: map['result'] as int?,
      amsID: map['amsID'] as String?,
      transactionId: map['transactionID'] as String?,
      // GPTom liefert Cent-Integers (ggf. als 1111.0), wir bleiben in Cent
      amountCents: ((map['amount'] as num?) ?? 0).round(),
      tipAmountCents: ((map['tipAmount'] as num?) ?? 0).round(),
      totalAmountCents: ((map['totalAmount'] as num?) ?? 0).round(),
      approvedCode: map['approvedCode'] as String?,
      batchNumber: map['batchNumber'] as String?,
      cardNumber: map['cardNumber'] as String?,
      cardDataEntry: map['cardDataEntry'] as String?,
      cardProduct: map['cardProduct'] as String?,
      currencyCode: map['currencyCode']?.toString(),
      date: map['date'] as String?,
      time: map['time'] as String?,
      emvAid: map['emvAid'] as String?,
      emvAppLable: map['emvAppLable'] as String?,
      externalTransactionID: map['externalTransactionID'] as String?,
      merchantID: map['merchantID'] as String?,
      merchantInfo: map['merchantInfo'] != null
          ? MerchantInfo.fromMap(Map<String, dynamic>.from(map['merchantInfo']))
          : null,
      pinOk: map['pinOk'] as bool?,
      printByPaymentApp: map['printByPaymentApp'] as bool?,
      responseMessage: map['responseMessage'] as String?,
      // Über die GPTom-ID mappen (1=SALE, 2=VOID, ...), nicht über den
      // Enum-Index – der ist verschoben (sell.index==0) und kennt 4 nicht.
      transactionType: TransactionType.fromId(map['transactionType']),
      sequenceNumber: map['sequenceNumber'] as String?,
      terminalID: map['terminalID'] as String?,
      // Fehler-Objekt:
      error: map['error'] != null
          ? ErrorInfo.fromMap(Map<String, dynamic>.from(map['error']), result: map['result'])
          : null,
    );
  }

  factory RequestResult.exception() {
    return RequestResult(result: -1001);
  }

  /// Aus einem JSON-String (falls dein Native Plugin einen JSON-String zurückgibt)
  factory RequestResult.fromJson(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is Map<String, dynamic>) {
      return RequestResult.fromMap(decoded);
    } else {
      return RequestResult.exception();
    }
  }

  @override
  String toString() {
    return 'RequestResult('
        'result=$result, '
        'amsID=$amsID, '
        'transactionId=$transactionId, '
        'amountCents=$amountCents, '
        'approvedCode=$approvedCode, '
        'responseMessage=$responseMessage, '
        'error=$error'
        ')';
  }

  Map<String, dynamic> toMap() {
    return {
      'result': result,
      'trasanctionID': transactionId,
      'approvedCode': approvedCode,
      'merchantID': merchantID,
      'terminalID': terminalID,
      // Cent-Format, wie es auch GPTom liefert
      'amount': amountCents,
      'tipAmount': tipAmountCents,
      'totalAmount': totalAmountCents,
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

/// Verschachtelte Klasse für merchantInfo
class MerchantInfo {
  final String? city;
  final String? company;
  final String? house;
  final String? street;
  final String? zip;

  MerchantInfo({
    this.city,
    this.company,
    this.house,
    this.street,
    this.zip,
  });

  factory MerchantInfo.fromMap(Map<String, dynamic> map) {
    return MerchantInfo(
      city: map['city'] as String?,
      company: map['company'] as String?,
      house: map['house'] as String?,
      street: map['street'] as String?,
      zip: map['zip'] as String?,
    );
  }

  @override
  String toString() {
    return 'MerchantInfo(city=$city, company=$company, house=$house, street=$street, zip=$zip)';
  }
}

/// Verschachtelte Klasse für das "error"-Objekt
class ErrorInfo {
  final String? errorCode;    // z. B. "1-097"
  final String? exception;    // "...InvalidParametersException..."
  final String? supportID;    // "To69eP"
  final int? result;

  ErrorInfo({this.errorCode, this.exception, this.supportID, this.result});

  factory ErrorInfo.fromMap(Map<String, dynamic> map, {int? result}) {
    return ErrorInfo(
      errorCode: map['errorCode'] as String?,
      exception: map['exception'] as String?,
      supportID: map['supportID'] as String?,
      result: result
    );
  }

  @override
  String toString() {
    return 'ErrorInfo(errorCode=$errorCode, exception=$exception, supportID=$supportID)';
  }

  String get errorMessage {
    switch (result) {
      case 0:
        return 'Die Zahlung war erfolgreich.';
      case -1:
        return 'Die Transaktion ist fehlgeschlagen.';
      case -2:
        return 'Ungültige Transaktions-ID – entweder nicht gesendet oder fehlerhafter Wert.';
      case -3:
        return 'Transaktion nicht gefunden. Dieser Code wird meist bei einer Abfrage (Inquiry) gesendet und bedeutet, dass die Transaktion erneut gestartet werden kann.';
      case -4:
        return 'Die Transaktion wurde abgelehnt.';
      case -5:
        return 'Die Transaktion wurde bereits storniert.';
      case -6:
        return 'Ungültige Parameter. Bitte prüfen Sie, ob alle Werte vorhanden sind und das richtige Format haben.';
      case -7:
        return 'Fehler, der Benutzer ist nicht autorisiert.';
      case -8:
        return 'Fehler, diese Operation ist nicht erlaubt.';
      case -9:
        return 'Eine Eingabe durch den Benutzer in GP tom ist erforderlich.';
      default:
        return 'Unbekannter Fehler.';
    }
  }
}