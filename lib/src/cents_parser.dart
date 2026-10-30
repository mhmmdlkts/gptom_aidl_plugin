/// Liest einen Euro-Betrag (Dezimal-String oder Zahl) als ganze Cent, ganz ohne
/// Fließkomma-Rechnung. Unlesbares ergibt `null`.
///
/// Regeln in dieser Reihenfolge:
/// 1. Leerzeichen entfernen.
/// 2. Kommen `.` und `,` beide vor, ist das letzte das Dezimalzeichen, die
///    anderen sind Tausender-Trennzeichen. Die Tausender-Gruppen müssen
///    gültig sein (siehe 3.), sonst `null` (`1.2.3,4`).
/// 3. Kommt nur eine Art vor, ist sie ein Tausender-Trennzeichen, wenn alle
///    Gruppen danach genau drei Ziffern haben und die erste Gruppe ein bis
///    drei Ziffern ohne führende Null (`1.234`, `1,234`, `1.234.567`; nur bei
///    String-Eingaben). `0,995` ist deshalb ein Dezimalwert. Kommt sie
///    mehrfach vor, ohne gültige Tausender-Gruppen zu bilden (`1.234.56`),
///    ist der Betrag unlesbar.
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

  String ganz;
  var nachkomma = '';
  if (punkte > 0 && kommas > 0) {
    final dezimalzeichen =
        text.lastIndexOf('.') > text.lastIndexOf(',') ? '.' : ',';
    final trenner = dezimalzeichen == '.' ? ',' : '.';
    final index = text.lastIndexOf(dezimalzeichen);
    final vorne = text.substring(0, index);
    nachkomma = text.substring(index + 1);
    // Das Dezimalzeichen darf vorne nicht nochmal vorkommen, die Trenner
    // müssen echte Tausender-Gruppen bilden.
    if (vorne.contains(dezimalzeichen)) return null;
    if (!_tausenderGruppen(vorne.split(trenner))) return null;
    ganz = vorne.replaceAll(trenner, '');
  } else if (punkte > 0 || kommas > 0) {
    final zeichen = punkte > 0 ? '.' : ',';
    final gruppen = text.split(zeichen);
    if (!istZahl && _tausenderGruppen(gruppen)) {
      ganz = gruppen.join();
    } else if (gruppen.length == 2) {
      ganz = gruppen[0];
      nachkomma = gruppen[1];
    } else {
      // Mehrfach, aber keine gültigen Tausender-Gruppen: unlesbar.
      return null;
    }
  } else {
    ganz = text;
  }
  if (ganz.isEmpty) ganz = '0';

  final aufgefuellt = nachkomma.padRight(2, '0');
  var cents = int.tryParse(ganz + aufgefuellt.substring(0, 2));
  if (cents == null) return null;
  if (aufgefuellt.length > 2 && aufgefuellt.codeUnitAt(2) >= 0x35) cents += 1;
  return negativ ? -cents : cents;
}

/// Bilden [gruppen] eine Zahl mit Tausender-Trennzeichen? Mindestens zwei
/// Gruppen, die erste mit ein bis drei Ziffern ohne führende Null, alle
/// weiteren mit genau drei Ziffern.
bool _tausenderGruppen(List<String> gruppen) {
  if (gruppen.length < 2) return false;
  final erste = gruppen.first;
  if (erste.isEmpty || erste.length > 3 || erste.startsWith('0')) return false;
  return gruppen.skip(1).every((g) => g.length == 3);
}
