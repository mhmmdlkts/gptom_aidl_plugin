import 'dart:convert';

/// Dart-Datenklasse für das Register-Ergebnis.
class RegisterResult {
  final int resultCode;
  final String? transactionId;
  final String? clientID;
  final String? responseMessage;
  // Falls du mehr Felder hast, füge sie hier hinzu.

  RegisterResult({
    required this.resultCode,
    this.transactionId,
    this.clientID,
    this.responseMessage,
  });

  /// Wenn dein Plugin bereits eine Map zurückliefert (z. B. `Map<String,dynamic>`).
  factory RegisterResult.fromMap(Map<String, dynamic> map) {
    return RegisterResult(
      resultCode: map['resultCode'] as int,
      transactionId: map['transactionId'] as String?,
      clientID: map['clientID'] as String?,
      responseMessage: map['responseMessage'] as String?,
    );
  }

  factory RegisterResult.formatException() {
    return RegisterResult(resultCode: -1001);
  }

  /// Falls dein Plugin nur einen JSON-String zurückgibt, kannst du ihn hier parsen.
  factory RegisterResult.fromJson(String jsonStr) {
    final map = jsonDecode(jsonStr);
    if (map is Map<String, dynamic>) {
      return RegisterResult.fromMap(map);
    } else {
      throw RegisterResult.formatException();
    }
  }

  @override
  String toString() {
    return 'RegisterResult('
        'resultCode=$resultCode, '
        'transactionId=$transactionId, '
        'clientID=$clientID, '
        'responseMessage=$responseMessage'
      ')';
  }
}