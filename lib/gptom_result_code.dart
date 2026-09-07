/// Ergebnis-Codes, an denen die aufrufende App entscheidet.
///
/// GP tom liefert eigene Codes (0 = Erfolg, -1 … -9, siehe README). Alles
/// darunter (ab -1001) entsteht im Plugin selbst und kommt nie von GP tom.
/// Die Konstanten sind bewusst öffentlich, damit in der Kasse keine nackten
/// Zahlen stehen müssen.
class GptomResultCode {
  const GptomResultCode._();

  // --- Codes von GP tom -----------------------------------------------------
  /// Zahlung erfolgreich (Karte belastet).
  static const int success = 0;

  /// Transaktion abgelehnt (GP tom Return-Code).
  static const int declined = -4;

  // --- Codes des Plugins ----------------------------------------------------
  /// Antwort fehlte oder war nicht parsebar (beide Plattformen).
  static const int exception = -1001;

  /// Die GP tom App ließ sich nicht öffnen (iOS). Sicher nichts belastet.
  static const int cannotOpen = -1002;

  /// Keine Antwort binnen der Frist – iOS: kein Redirect, Android: der
  /// Wächter auf `requestTransactionV2`. GP tom kann die Zahlung trotzdem zu
  /// Ende führen, die Karte kann also belastet sein.
  static const int timeout = -1003;

  /// Redirect ohne Beleg und ohne Erfolgs-Status (iOS).
  static const int noReceipt = -1004;

  /// Der Beleg im Redirect war nicht lesbar (iOS). Bewusst NICHT [timeout]:
  /// eine belastete Karte darf nicht als Zeitablauf erscheinen.
  static const int parseError = -1005;

  /// Abbruch durch Kassier oder Kunde (iOS: `TASK_STATUS=CANCELED`).
  static const int cancelled = -1006;

  /// Ausgänge, bei denen die Karte belastet sein KANN. Die App muss hier
  /// nachfragen (Android: `stateRequest`/`inquireTransaction`, iOS: den
  /// gepufferten Redirect) statt die Zahlung zu wiederholen.
  static const Set<int> unklar = {timeout, noReceipt, parseError, exception};

  /// Ausgänge, bei denen sicher nichts belastet wurde – nur diese darf die
  /// App gefahrlos wiederholen.
  static const Set<int> ohneBelastung = {cannotOpen, cancelled};

  static bool istUnklar(int? result) => result != null && unklar.contains(result);

  static bool istOhneBelastung(int? result) =>
      result != null && ohneBelastung.contains(result);
}

/// Fehlerkennungen in `RequestResult.error.errorCode` für die
/// Plugin-eigenen Ausgänge. Android-Wächter und iOS-Zeitablauf melden
/// denselben Wert, damit die App nur einen Weg braucht.
class GptomErrorCode {
  const GptomErrorCode._();

  static const String timeout = 'TIMEOUT';
  static const String cannotOpen = 'CANNOT_OPEN';
  static const String noReceipt = 'NO_RECEIPT';
  static const String parseError = 'PARSE_ERROR';
  static const String cancelled = 'CANCELLED';
  static const String declined = 'DECLINED';
}
