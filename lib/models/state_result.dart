import 'dart:convert';

enum StateStatus {
  created(1, true, false, false),
  started(2, true, false, false),
  initError(3, true, false, false),
  inProgress(5, false, false, false),
  completed(6, false, true, true),
  cancelled(7, false, true, true),
  error(8, false, true, true),
  unknown(-1, true, false, false);

  final int value;
  final bool isRepeatable;
  final bool finishedTrx;
  final bool finished;
  const StateStatus(this.value, this.isRepeatable, this.finishedTrx, this.finished);
}

class StateResult {
  /// resultCode ist nun Pflicht (nicht null).
  final int resultCode;

  /// transactionId kann optional sein
  final String? transactionId;

  /// state wird in ein Enum `StateStatus` umgesetzt
  final StateStatus state;

  /// isRepeatable kann optional sein
  final bool? isRepeatable;

  /// created und updated als DateTime
  final DateTime? created;
  final DateTime? updated;

  /// ggf. Fehler-Objekt
  final StateErrorResult? error;

  StateResult({
    required this.resultCode,
    this.transactionId,
    this.isRepeatable,
    this.created,
    this.updated,
    this.error,
    this.state = StateStatus.unknown,
  });

  factory StateResult.fromMap(Map<String, dynamic> map) {
    final int resultCode = map['resultCode'] is int
        ? map['resultCode'] as int
        : int.tryParse(map['resultCode']?.toString() ?? '-1001') ?? -1001;

    // 2) state => Enum
    //    Wir versuchen, den int-Wert in unser StateStatus zu konvertieren.
    //    Evtl. hast du diese Werte aus GPTom-Doku: 1=CREATED,2=STARTED,3=INIT_ERROR,5=IN_PROGRESS,6=COMPLETED,7=CANCELLED,8=ERROR...
    final int rawState = map['state'] is int ? map['state'] as int : 0;
    final StateStatus parsedState = StateStatus.values
        .firstWhere((element) => element.value == rawState, orElse: () => StateStatus.unknown);

    // 3) created, updated => DateTime
    //    Annahme: GPTom liefert ISO-String z. B. "2023-09-11T12:29:11.300Z"
    final String? createdStr = map['created'] as String?;
    final String? updatedStr = map['updated'] as String?;
    final DateTime? created = (createdStr != null) ? DateTime.tryParse(createdStr) : null;
    final DateTime? updated = (updatedStr != null) ? DateTime.tryParse(updatedStr) : null;

    return StateResult(
      resultCode: resultCode,
      transactionId: map['transactionId'] as String?,
      state: parsedState,
      isRepeatable: map['isRepeatable'] as bool?,
      created: created,
      updated: updated,
      error: map['error'] != null
          ? StateErrorResult.fromMap(Map<String, dynamic>.from(map['error']))
          : null,
    );
  }

  /// Parst den JSON-String aus dem nativen Callback. Liefert bei kaputtem
  /// oder unerwartetem JSON ein Fehler-Ergebnis (resultCode -1001) statt zu
  /// werfen – die GP tom Antwort ist Fremd-Input.
  factory StateResult.fromJson(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        return StateResult.fromMap(decoded);
      }
    } catch (_) {
      // fällt unten auf exception zurück
    }
    return StateResult.exception();
  }

  factory StateResult.exception() {
    return StateResult(
      resultCode: -1001,
      error: StateErrorResult(
        code: -1001,
        internalErrorCode: -1001,
        internalErrorSubCode: -1001,
        platform: 'unknown',
      ),
    );
  }

  @override
  String toString() {
    return 'StateResult('
        'resultCode=$resultCode, '
        'transactionId=$transactionId, '
        'state=$state, '
        'created=$created, '
        'updated=$updated, '
        'error=$error'
        ')';
  }
}

/// Beispiel für ein Error-Objekt (frei definierbar)
class StateErrorResult {
  /// z. B. code, internalErrorCode, internalErrorSubCode, platform...
  final int? code;
  final int? internalErrorCode;
  final int? internalErrorSubCode;
  final String? platform;

  StateErrorResult({
    this.code,
    this.internalErrorCode,
    this.internalErrorSubCode,
    this.platform,
  });

  factory StateErrorResult.fromMap(Map<String, dynamic> map) {
    return StateErrorResult(
      code: map['code'] as int?,
      internalErrorCode: map['internalErrorCode'] as int?,
      internalErrorSubCode: map['internalErrorSubCode'] as int?,
      platform: map['platform'] as String?,
    );
  }

  @override
  String toString() {
    return 'StateErrorResult(code=$code,internalErrorCode=$internalErrorCode,platform=$platform)';
  }

  String? get errorMessage {
    switch (code) {
      case 0:
        return 'Unbekannter Fehler.';
      case 65:
        return 'Transaktion abgelaufen.';
      case 104:
        return 'Technischer Fehler.';
      default:
        return null;
    }
  }

  bool get isRetryable {
    return code == 65 || code == 104;
  }
}