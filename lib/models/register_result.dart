import 'dart:convert';

import 'request_result.dart';

/// Ergebnis von transactionRegisterV2 (RegisterResultV2Entity).
class RegisterResult {
  final int resultCode;
  final String? transactionId;
  final String? clientID;
  final String? responseMessage;

  /// Fehler-Objekt, falls die Registrierung fehlschlägt.
  final ErrorInfo? error;

  bool get isSuccess => resultCode == 0 && transactionId != null;

  RegisterResult({
    required this.resultCode,
    this.transactionId,
    this.clientID,
    this.responseMessage,
    this.error,
  });

  factory RegisterResult.fromMap(Map<String, dynamic> map) {
    final rawResultCode = map['resultCode'];
    return RegisterResult(
      resultCode: rawResultCode is num
          ? rawResultCode.toInt()
          : int.tryParse('$rawResultCode') ?? -1001,
      transactionId: map['transactionId'] as String?,
      clientID: map['clientID'] as String?,
      responseMessage: map['responseMessage'] as String?,
      error: map['error'] is Map
          ? ErrorInfo.fromMap(Map<String, dynamic>.from(map['error'] as Map))
          : null,
    );
  }

  factory RegisterResult.formatException() {
    return RegisterResult(resultCode: -1001);
  }

  /// Parst den JSON-String aus dem nativen Callback. Liefert bei kaputtem
  /// oder unerwartetem JSON ein Fehler-Ergebnis (resultCode -1001) statt zu
  /// werfen – die GP tom Antwort ist Fremd-Input.
  factory RegisterResult.fromJson(String jsonStr) {
    try {
      final map = jsonDecode(jsonStr);
      if (map is Map<String, dynamic>) {
        return RegisterResult.fromMap(map);
      }
    } catch (_) {
      // fällt unten auf formatException zurück
    }
    return RegisterResult.formatException();
  }

  @override
  String toString() {
    return 'RegisterResult('
        'resultCode=$resultCode, '
        'transactionId=$transactionId, '
        'clientID=$clientID, '
        'responseMessage=$responseMessage, '
        'error=$error'
      ')';
  }
}
