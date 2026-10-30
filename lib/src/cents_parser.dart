/// Liest einen Euro-Betrag (Dezimal-String oder Zahl) als ganze Cent, ganz ohne
/// Fließkomma-Rechnung. Unlesbares ergibt `null`.
///
/// Regeln in dieser Reihenfolge:
/// 1. Leerzeichen entfernen.
/// 2. Kommen `.` und `,` beide vor, ist das letzte das Dezimalzeichen, die
///    anderen sind Tausender-Trennzeichen.
/// 3. Kommt nur eine Art vor, aber mehrfach (`1.234.567`), oder genau einmal
///    mit genau drei Ziffern danach (`1.234`, `1,234`), ist es ein
///    Tausender-Trennzeichen (nur bei String-Eingaben).
/// 4. Sonst ist es das Dezimalzeichen. Nachkommastellen auf zwei auffüllen,
///    mehr als zwei kaufmännisch runden (über den Betrag, Vorzeichen bleibt).
/// 5. Zahlen (`num`): `toString()`, `.` ist immer das Dezimalzeichen.
int? centsFromDecimal(Object? value) {
  if (value == null) return null;
  final istZahl = value is num;
  if (!istZahl && value is! String) return null;

  var text = value.toString().replaceAll(RegExp(r'\s'), '');
  var negativ = false;
  if (text.startsWith('-')) {
    negativ = true;
    text = text.substring(1);
  }
  if (!RegExp(r'^[0-9.,]*[0-9][0-9.,]*$').hasMatch(text)) return null;

  final punkte = '.'.allMatches(text).length;
  final kommas = ','.allMatches(text).length;

  String? dezimalzeichen;
  if (punkte > 0 && kommas > 0) {
    dezimalzeichen = text.lastIndexOf('.') > text.lastIndexOf(',') ? '.' : ',';
  } else if (punkte > 0 || kommas > 0) {
    final zeichen = punkte > 0 ? '.' : ',';
    final anzahl = punkte > 0 ? punkte : kommas;
    final nachkomma = text.length - text.lastIndexOf(zeichen) - 1;
    final tausender = !istZahl && (anzahl > 1 || nachkomma == 3);
    dezimalzeichen = tausender ? null : zeichen;
    if (dezimalzeichen != null && anzahl > 1) return null;
  }

  String ganz;
  String nachkomma = '';
  if (dezimalzeichen == null) {
    ganz = text.replaceAll('.', '').replaceAll(',', '');
  } else {
    final index = text.lastIndexOf(dezimalzeichen);
    final anderes = dezimalzeichen == '.' ? ',' : '.';
    ganz = text.substring(0, index);
    nachkomma = text.substring(index + 1);
    // Dezimalzeichen darf vorne nicht nochmal vorkommen, hinten kein Trenner
    if (ganz.contains(dezimalzeichen) || nachkomma.contains(anderes)) {
      return null;
    }
    ganz = ganz.replaceAll(anderes, '');
  }
  if (ganz.isEmpty) ganz = '0';

  final aufgefuellt = nachkomma.padRight(2, '0');
  var cents = int.tryParse(ganz + aufgefuellt.substring(0, 2));
  if (cents == null) return null;
  if (aufgefuellt.length > 2 && aufgefuellt.codeUnitAt(2) >= 0x35) cents += 1;
  return negativ ? -cents : cents;
}
