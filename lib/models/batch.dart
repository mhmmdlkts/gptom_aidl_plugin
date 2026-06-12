import 'dart:convert';

class Batch implements Comparable<Batch> {
  final int saleCount;
  final DateTime? previousBatchDate;
  final int voidCount;
  final DateTime? firstTransactionDate;

  /// in Cent (GPTom liefert im Batch-JSON Euro-Dezimalwerte, wir rechnen um)
  final int saleAmountCents;
  final int invalidCount;
  final String communicationId;
  final DateTime date;
  final int totalCount;
  final int voidAmountCents;
  final Map<String, SubBatch> subBatches;
  final String currency;
  final int totalAmountCents;
  final String amsId;

  SubBatch get cardBatch => subBatches['CARD']!;
  SubBatch get goCryptoBatch => subBatches['GO_CRYPTO']!;
  SubBatch get cashBatch => subBatches['CASH']!;
  SubBatch get accountPaymentBatch => subBatches['ACCOUNT_PAYMENT']!;

  bool get isSuccess => amsId.isNotEmpty; // TODO check on error

  /// Komfort-Getter für Anzeigen in Euro.
  double get saleAmountEuro => saleAmountCents / 100;
  double get voidAmountEuro => voidAmountCents / 100;
  double get totalAmountEuro => totalAmountCents / 100;

  Batch({
    required this.saleCount,
    required this.previousBatchDate,
    required this.voidCount,
    required this.firstTransactionDate,
    required this.saleAmountCents,
    required this.invalidCount,
    required this.communicationId,
    required this.date,
    required this.totalCount,
    required this.voidAmountCents,
    required this.subBatches,
    required this.currency,
    required this.totalAmountCents,
    required this.amsId,
  });

  /// GPTom liefert die Batch-Beträge als Euro-Dezimalwerte (z. B. 95.5).
  static int _centsFromEuro(num value) => (value * 100).round();

  factory Batch.fromJson(Map<String, dynamic> json) {
    return Batch(
      saleCount: json['saleCount'],
      previousBatchDate: json['previousBatchDate']!=null?DateTime.parse(json['previousBatchDate']):null,
      voidCount: json['voidCount'],
      firstTransactionDate: json['firstTransactionDate']!=null?DateTime.parse(json['firstTransactionDate']):null,
      saleAmountCents: _centsFromEuro(json['saleAmount'] as num),
      invalidCount: json['invalidCount'],
      communicationId: json['communicationId'],
      date: DateTime.parse(json['date']),
      totalCount: json['totalCount'],
      voidAmountCents: _centsFromEuro(json['voidAmount'] as num),
      subBatches: (json['subBatches'] as Map<String, dynamic>).map((key, value) => MapEntry(key, SubBatch.fromJson(value))),
      currency: json['currency'],
      totalAmountCents: _centsFromEuro(json['totalAmount'] as num),
      amsId: json['amsId'],
    );
  }

  factory Batch.fromQuery(String string) {
    return Batch.fromJson(jsonDecode(string));
  }

  Map<String, dynamic> toJson() {
    return {
      'saleCount': saleCount,
      'previousBatchDate': previousBatchDate?.toIso8601String(),
      'voidCount': voidCount,
      'firstTransactionDate': firstTransactionDate?.toIso8601String(),
      // Euro-Dezimalformat, damit toJson/fromJson zum GPTom-Format passt
      'saleAmount': saleAmountCents / 100,
      'invalidCount': invalidCount,
      'communicationId': communicationId,
      'date': date.toIso8601String(),
      'totalCount': totalCount,
      'voidAmount': voidAmountCents / 100,
      'subBatches': subBatches.map((key, value) => MapEntry(key, value.toJson())),
      'currency': currency,
      'totalAmount': totalAmountCents / 100,
      'amsId': amsId,
    };
  }

  String get readableTime => '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';


  @override
  int compareTo(other) => date.compareTo(other.date);
}

class SubBatch {
  final int voidCount;
  final int totalCount;

  /// in Cent
  final int saleAmountCents;
  final int voidAmountCents;
  final int saleCount;
  final String closeBatchNumber;
  final int totalAmountCents;

  bool get exists => totalCount > 0 && totalAmountCents != 0 && saleCount > 0 && voidCount > 0 && voidAmountCents != 0 && saleAmountCents != 0;

  /// Komfort-Getter für Anzeigen in Euro.
  double get saleAmountEuro => saleAmountCents / 100;
  double get voidAmountEuro => voidAmountCents / 100;
  double get totalAmountEuro => totalAmountCents / 100;

  SubBatch({
    required this.voidCount,
    required this.totalCount,
    required this.saleAmountCents,
    required this.voidAmountCents,
    required this.saleCount,
    required this.closeBatchNumber,
    required this.totalAmountCents,
  });

  factory SubBatch.fromJson(Map<String, dynamic> json) {
    return SubBatch(
      voidCount: json['voidCount'],
      totalCount: json['totalCount'],
      saleAmountCents: Batch._centsFromEuro(json['saleAmount'] as num),
      voidAmountCents: Batch._centsFromEuro(json['voidAmount'] as num),
      saleCount: json['saleCount'],
      closeBatchNumber: json['closeBatchNumber'],
      totalAmountCents: Batch._centsFromEuro(json['totalAmount'] as num),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'voidCount': voidCount,
      'totalCount': totalCount,
      'saleAmount': saleAmountCents / 100,
      'voidAmount': voidAmountCents / 100,
      'saleCount': saleCount,
      'closeBatchNumber': closeBatchNumber,
      'totalAmount': totalAmountCents / 100,
    };
  }
}
