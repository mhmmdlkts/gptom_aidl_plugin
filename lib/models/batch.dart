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

  /// Null-sicherer Zugriff auf einen SubBatch (z. B. 'CARD', 'CASH').
  SubBatch? subBatch(String key) => subBatches[key];

  /// Achtung: werfen, wenn GP tom den jeweiligen SubBatch nicht liefert –
  /// im Zweifel [subBatch] verwenden.
  SubBatch get cardBatch => subBatches['CARD']!;
  SubBatch get goCryptoBatch => subBatches['GO_CRYPTO']!;
  SubBatch get cashBatch => subBatches['CASH']!;
  SubBatch get accountPaymentBatch => subBatches['ACCOUNT_PAYMENT']!;

  bool get isSuccess => amsId.isNotEmpty;

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

  static int _asInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  static int _asCents(dynamic value) {
    if (value is num) return _centsFromEuro(value);
    final parsed = double.tryParse('$value');
    return parsed == null ? 0 : _centsFromEuro(parsed);
  }

  static DateTime? _asDate(dynamic value) =>
      value == null ? null : DateTime.tryParse(value.toString());

  /// Defensiv geparst: fehlende/unerwartete Felder werden zu 0/''/null statt
  /// zu werfen – der Batch kommt als Fremd-Input aus dem GPTom-Redirect.
  factory Batch.fromJson(Map<String, dynamic> json) {
    return Batch(
      saleCount: _asInt(json['saleCount']),
      previousBatchDate: _asDate(json['previousBatchDate']),
      voidCount: _asInt(json['voidCount']),
      firstTransactionDate: _asDate(json['firstTransactionDate']),
      saleAmountCents: _asCents(json['saleAmount']),
      invalidCount: _asInt(json['invalidCount']),
      communicationId: json['communicationId']?.toString() ?? '',
      date: _asDate(json['date']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      totalCount: _asInt(json['totalCount']),
      voidAmountCents: _asCents(json['voidAmount']),
      subBatches: json['subBatches'] is Map
          ? Map<String, dynamic>.from(json['subBatches'] as Map).map(
              (key, value) => MapEntry(
                  key, SubBatch.fromJson(Map<String, dynamic>.from(value as Map))))
          : const {},
      currency: json['currency']?.toString() ?? '',
      totalAmountCents: _asCents(json['totalAmount']),
      amsId: json['amsId']?.toString() ?? '',
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

  /// Ob in diesem SubBatch überhaupt Transaktionen enthalten sind.
  bool get exists => totalCount > 0 || totalAmountCents != 0;

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
      voidCount: Batch._asInt(json['voidCount']),
      totalCount: Batch._asInt(json['totalCount']),
      saleAmountCents: Batch._asCents(json['saleAmount']),
      voidAmountCents: Batch._asCents(json['voidAmount']),
      saleCount: Batch._asInt(json['saleCount']),
      closeBatchNumber: json['closeBatchNumber']?.toString() ?? '',
      totalAmountCents: Batch._asCents(json['totalAmount']),
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
