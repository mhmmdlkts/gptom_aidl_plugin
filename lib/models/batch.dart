import 'dart:convert';

class Batch implements Comparable<Batch> {
  final int saleCount;
  final DateTime? previousBatchDate;
  final int voidCount;
  final DateTime? firstTransactionDate;
  final double saleAmount;
  final int invalidCount;
  final String communicationId;
  final DateTime date;
  final int totalCount;
  final double voidAmount;
  final Map<String, SubBatch> subBatches;
  final String currency;
  final double totalAmount;
  final String amsId;

  SubBatch get cardBatch => subBatches['CARD']!;
  SubBatch get goCryptoBatch => subBatches['GO_CRYPTO']!;
  SubBatch get cashBatch => subBatches['CASH']!;
  SubBatch get accountPaymentBatch => subBatches['ACCOUNT_PAYMENT']!;

  bool get isSuccess => amsId.isNotEmpty; // TODO check on error

  Batch({
    required this.saleCount,
    required this.previousBatchDate,
    required this.voidCount,
    required this.firstTransactionDate,
    required this.saleAmount,
    required this.invalidCount,
    required this.communicationId,
    required this.date,
    required this.totalCount,
    required this.voidAmount,
    required this.subBatches,
    required this.currency,
    required this.totalAmount,
    required this.amsId,
  });

  factory Batch.fromJson(Map<String, dynamic> json) {
    return Batch(
      saleCount: json['saleCount'],
      previousBatchDate: json['previousBatchDate']!=null?DateTime.parse(json['previousBatchDate']):null,
      voidCount: json['voidCount'],
      firstTransactionDate: json['firstTransactionDate']!=null?DateTime.parse(json['firstTransactionDate']):null,
      saleAmount: (json['saleAmount'] as num).toDouble(),
      invalidCount: json['invalidCount'],
      communicationId: json['communicationId'],
      date: DateTime.parse(json['date']),
      totalCount: json['totalCount'],
      voidAmount: (json['voidAmount'] as num).toDouble(),
      subBatches: (json['subBatches'] as Map<String, dynamic>).map((key, value) => MapEntry(key, SubBatch.fromJson(value))),
      currency: json['currency'],
      totalAmount: (json['totalAmount'] as num).toDouble(),
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
      'saleAmount': saleAmount,
      'invalidCount': invalidCount,
      'communicationId': communicationId,
      'date': date.toIso8601String(),
      'totalCount': totalCount,
      'voidAmount': voidAmount,
      'subBatches': subBatches.map((key, value) => MapEntry(key, value.toJson())),
      'currency': currency,
      'totalAmount': totalAmount,
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
  final double saleAmount;
  final double voidAmount;
  final int saleCount;
  final String closeBatchNumber;
  final double totalAmount;

  bool get exists => totalCount > 0 && totalAmount != 0 && saleCount > 0 && voidCount > 0 && voidAmount != 0 && saleAmount != 0;

  SubBatch({
    required this.voidCount,
    required this.totalCount,
    required this.saleAmount,
    required this.voidAmount,
    required this.saleCount,
    required this.closeBatchNumber,
    required this.totalAmount,
  });

  factory SubBatch.fromJson(Map<String, dynamic> json) {
    return SubBatch(
      voidCount: json['voidCount'],
      totalCount: json['totalCount'],
      saleAmount: (json['saleAmount'] as num).toDouble(),
      voidAmount: (json['voidAmount'] as num).toDouble(),
      saleCount: json['saleCount'],
      closeBatchNumber: json['closeBatchNumber'],
      totalAmount: (json['totalAmount'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'voidCount': voidCount,
      'totalCount': totalCount,
      'saleAmount': saleAmount,
      'voidAmount': voidAmount,
      'saleCount': saleCount,
      'closeBatchNumber': closeBatchNumber,
      'totalAmount': totalAmount,
    };
  }
}