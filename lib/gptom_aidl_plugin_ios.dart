import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gptom_aidl_plugin/gptom_result_code.dart';
import 'package:gptom_aidl_plugin/gptom_security.dart';
import 'package:gptom_aidl_plugin/models/batch.dart';
import 'package:gptom_aidl_plugin/src/cents_parser.dart';
import 'package:url_launcher/url_launcher.dart';
import 'enums/preferable_receipt_type.dart';
import 'enums/transaction_methode.dart';
import 'enums/transaction_type.dart';
import 'models/request_result.dart';

/// Ein Redirect aus GP tom, für den es keinen wartenden Aufruf gab –
/// typischerweise nach einem Kaltstart (iOS hat die Kasse beendet, während
/// GP tom vorn war) oder ein verspäteter Redirect einer früheren Zahlung.
/// Späte Redirects von Status, Login & Co. landen nicht hier (Token-Modus).
///
/// Die App holt ihn mit [GptomAidlPluginIOS.pendingRedirect] ab: am
/// sichersten über die `requestId` aus ihrem eigenen Speicher (vor dem
/// Aufruf gesichert; bestätigt den Redirect auch nach einem Kaltstart),
/// sonst über [originReferenceNum].
///
/// Ein unbestätigter Redirect ([isVerified] == false) kann gefälscht sein –
/// jeder kann `<scheme>://redirect?status=COMPLETED` öffnen, auch mit einem
/// selbst gewählten Token im Pfad. Er ergibt deshalb nie Erfolg, sondern
/// [GptomResultCode.unverified], und gibt keine Vorgangskennung heraus.
class GptomPendingRedirect {
  /// Der rohe Redirect, wie GP tom ihn geschickt hat.
  final Uri uri;

  /// Zeitpunkt des Eingangs (Gerätezeit).
  final DateTime receivedAt;

  /// Stammt der Redirect nachweislich aus GP tom und gehört er zu einer
  /// Zahlung? Im Token-Modus nur, wenn er das Token einer Zahlung (Verkauf,
  /// Storno, Rückerstattung) trägt, die dieser Prozess gestartet hat und die
  /// noch nicht beantwortet bzw. abgeholt wurde, oder wenn die App ihn über
  /// `pendingRedirect(requestId: …)` zum ersten Mal abgeholt hat. Eine Kopie
  /// eines schon beantworteten Redirects ist unbestätigt. Im Altmodus
  /// (`GptomSecurityConfig.redirectTokenIOS = false`) immer `true`.
  final bool isVerified;

  GptomPendingRedirect(this.uri, this.receivedAt, {this.isVerified = true});

  /// Referenz aus dem Redirect (`referenceNumber` bzw. `originReferenceNum`),
  /// also genau der Wert, den die App bei `sell` mitgegeben hat.
  String? get originReferenceNum => GptomAidlPluginIOS.referenceFromRedirect(uri);

  /// Vorgangskennung (Token aus dem Redirect-Pfad) – nur bei einem
  /// bestätigten Redirect, sonst `null`.
  ///
  /// Bei einem unbestätigten Redirect hat der Absender das Token selbst
  /// gewählt. Würde es hier herausgegeben, könnte die App es an
  /// `pendingRedirect(requestId: …)` weiterreichen und damit eine Fälschung
  /// bestätigen. Die Kennung für `pendingRedirect` stammt deshalb immer aus
  /// dem eigenen Speicher der App, nie aus einem Redirect oder Ergebnis.
  String? get requestId =>
      isVerified ? GptomAidlPluginIOS.tokenFromRedirect(uri) : null;

  /// `TASK_STATUS` aus dem Redirect (COMPLETED, CANCELED, ERROR).
  String? get status => uri.queryParameters['status'];

  /// Liest den Redirect als Ergebnis eines Verkaufs. Unbestätigt:
  /// [GptomResultCode.unverified], nie Erfolg.
  RequestResult asSellResult({bool printByPaymentApp = false}) {
    if (!isVerified) return _unbestaetigt();
    return GptomAidlPluginIOS.requestResultFromCreateRedirect(
      uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
      requestId: requestId,
    );
  }

  /// Liest den Redirect als Ergebnis eines Stornos. Unbestätigt:
  /// [GptomResultCode.unverified], nie Erfolg.
  RequestResult asVoidResult({bool printByPaymentApp = false}) {
    if (!isVerified) return _unbestaetigt();
    return GptomAidlPluginIOS.requestResultFromCancelRedirect(
      uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
      requestId: requestId,
    );
  }

  /// Liest den Redirect als Ergebnis einer Rückerstattung. Unbestätigt:
  /// [GptomResultCode.unverified], nie Erfolg.
  RequestResult asRefundResult({bool printByPaymentApp = false}) {
    if (!isVerified) return _unbestaetigt();
    return GptomAidlPluginIOS.requestResultFromRefundRedirect(
      uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
      requestId: requestId,
    );
  }

  /// Der Inhalt des Redirects wird gar nicht erst ausgewertet: Ein
  /// gefälschter Link mit erratbarer Rechnungsnummer darf nichts als bezahlt
  /// verbuchen. Bewusst ohne `requestId` – das Token im Pfad hat der
  /// Absender gewählt. Die Kasse klärt den Fall mit der Vorgangskennung aus
  /// ihrem eigenen Speicher (`pendingRedirect(requestId: …)` bzw.
  /// `transactionDetailIOS`).
  RequestResult _unbestaetigt() => RequestResult(
        result: GptomResultCode.unverified,
        responseMessage: 'Redirect nicht bestätigt',
        error: ErrorInfo(
          errorCode: GptomErrorCode.unverified,
          result: GptomResultCode.unverified,
        ),
      );

  @override
  String toString() =>
      'GptomPendingRedirect(originReferenceNum=$originReferenceNum, '
      'status=$status, isVerified=$isVerified, receivedAt=$receivedAt)';
}

/// Art des Aufrufs, für den ein Token ausgegeben wurde. Nur ein später
/// Redirect zu einer Zahlung (Verkauf, Storno, Rückerstattung) kann als
/// bestätigter Eintrag in den Puffer kommen.
enum _TokenArt { zahlung, sonstige }

/// Wartet auf den Redirect eines bestimmten Aufrufs.
class _RedirectWaiter {
  /// Token-Modus: das Token aus der eigenen `redirectUrl`. `null` heißt
  /// Altmodus (Zuordnung über die Referenz).
  final String? token;
  final String? expectedReference;
  final Completer<Uri> completer = Completer<Uri>();

  _RedirectWaiter({this.token, this.expectedReference});

  bool accepts(Uri uri) {
    final eigenesToken = token;
    if (eigenesToken != null) {
      // Token-Modus: nur genau dieses Token. Die Referenz zählt hier nicht –
      // eine Rechnungsnummer ist erratbar, das Token nicht.
      return GptomAidlPluginIOS.tokenFromRedirect(uri) == eigenesToken;
    }
    // Altmodus: Ein Redirect ohne erkennbare Referenz wird angenommen –
    // GP tom liefert die Referenz nur zurück, wenn sie mitgegeben wurde, und
    // ältere App-Versionen kennen das Feld nicht.
    final reference = GptomAidlPluginIOS.referenceFromRedirect(uri);
    return expectedReference == null ||
        reference == null ||
        reference == expectedReference;
  }
}

class GptomAidlPluginIOS {

  /// Roher Strom aller Redirects auf das eigene App-Scheme.
  ///
  /// Achtung: Der Strom führt auch gefälschte Redirects (jede App kann
  /// `<scheme>://redirect/...` öffnen). Daraus **nie** Zahlungen verbuchen;
  /// dafür gibt es `sell` und `pendingRedirect(requestId:)`.
  static final StreamController<Uri> gptomRedirectStream = StreamController<Uri>.broadcast();
  static AppLinks? _appLinks;
  static StreamSubscription<Uri>? _redirectSubscription;
  static bool _isListening = false;
  static String _expectedScheme = '';
  static String _redirectUrl = 'xxx://redirect';

  static final List<_RedirectWaiter> _waiters = [];
  static final List<GptomPendingRedirect> _pendingRedirects = [];

  /// So viele unzugeordnete Redirects bleiben gemerkt; ältere fallen heraus.
  static const int maxPendingRedirects = 10;

  /// Tokens, die dieser Prozess an GP tom geschickt hat und deren Redirect
  /// noch aussteht, mit der Art des Aufrufs (Einfügereihenfolge, älteste
  /// zuerst). Nur ein Zahlungs-Token macht einen gepufferten Redirect ohne
  /// Wartenden zu einem bestätigten. Nach einem Kaltstart ist die Tabelle
  /// leer – dann bestätigt die App über `pendingRedirect(requestId: …)`.
  static final Map<String, _TokenArt> _ausgegebeneTokens = <String, _TokenArt>{};

  /// Tokens, deren Redirect schon beantwortet oder abgeholt wurde. Eine
  /// spätere Kopie desselben Redirects (GP tom schickt ihn erneut) bleibt
  /// damit unbestätigt – auch über `pendingRedirect(requestId: …)`.
  static final Set<String> _verbrauchteTokens = <String>{};

  /// So viele ausgegebene bzw. verbrauchte Tokens bleiben gemerkt; ältere
  /// fallen heraus.
  static const int _maxAusgegebeneTokens = 50;

  /// Format von Token und Vorgangskennung: 32 Hex-Zeichen, klein. Hex
  /// enthält keine der Zeichenfolgen, an denen GP tom den Anfrage-Typ per
  /// `contains` erkennt (`login`, `status`, `transaction/…`, …).
  static final RegExp _tokenMuster = RegExp(r'^[0-9a-f]{32}$');

  static final Random _zufall = Random.secure();

  /// Die Redirect-URL, die GP tom mitgegeben wird (ohne Token).
  @visibleForTesting
  static String get redirectUrl => _redirectUrl;

  /// Die Redirect-URL für einen Aufruf: mit Token `<scheme>://redirect/<token>`,
  /// ohne (Altmodus) `<scheme>://redirect`. Bewusst kein Operationsname im
  /// Pfad, siehe [_tokenMuster].
  @visibleForTesting
  static String redirectUrlFuer(String? token) =>
      token == null ? _redirectUrl : '$_redirectUrl/$token';

  /// Erzeugt eine Vorgangskennung bzw. ein Redirect-Token: 32 Hex-Zeichen
  /// (klein) aus [Random.secure]. Ein Angreifer kann sie nicht erraten.
  /// Eine Kennung je Zahlungsversuch, nie wiederverwenden.
  static String neueVorgangsId() {
    final buffer = StringBuffer();
    for (var i = 0; i < 16; i++) {
      buffer.write(_zufall.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Token aus einem Redirect: genau ein Pfadsegment aus 32 Hex-Zeichen bei
  /// Host `redirect`, sonst `null`.
  static String? tokenFromRedirect(Uri uri) {
    if (uri.host != 'redirect') return null;
    final segmente = uri.pathSegments;
    if (segmente.length != 1) return null;
    final token = segmente.single;
    return _tokenMuster.hasMatch(token) ? token : null;
  }

  static void _merkeToken(String token, _TokenArt art) {
    _ausgegebeneTokens.remove(token);
    _ausgegebeneTokens[token] = art;
    while (_ausgegebeneTokens.length > _maxAusgegebeneTokens) {
      _ausgegebeneTokens.remove(_ausgegebeneTokens.keys.first);
    }
  }

  /// Der Redirect zu [token] ist beantwortet bzw. abgeholt: Das Token
  /// bestätigt danach nichts mehr.
  static void _verbrauchen(String? token) {
    if (token == null) return;
    _ausgegebeneTokens.remove(token);
    _verbrauchteTokens.remove(token);
    _verbrauchteTokens.add(token);
    while (_verbrauchteTokens.length > _maxAusgegebeneTokens) {
      _verbrauchteTokens.remove(_verbrauchteTokens.first);
    }
  }

  /// Setzt das eigene App-Scheme, ohne den Listener zu starten.
  static void _setRedirectScheme(String uriScheme) {
    // Scheme als Feld halten, damit der Filter auch bei einem späteren
    // Aufruf mit anderem Scheme zur Redirect-URL passt.
    _expectedScheme = uriScheme;
    _redirectUrl = '$uriScheme://redirect';
  }

  @visibleForTesting
  static void debugSetRedirectScheme(String uriScheme) => _setRedirectScheme(uriScheme);

  /// Registriert den Listener auf Redirects. Idempotent – ein zweiter Aufruf
  /// aktualisiert nur das Scheme. Darf (und soll) beim App-Start laufen,
  /// damit ein Redirect nach einem Kaltstart nicht ins Leere geht.
  static void listenForGptomRedirectsIOS(String uriScheme) {
    _setRedirectScheme(uriScheme);
    if (_isListening) return;

    try {
      // Nicht `late final`: schlägt der Aufbau fehl, muss ein zweiter Versuch
      // möglich bleiben (sonst lauscht die App dauerhaft nicht mehr).
      final links = _appLinks ??= AppLinks();
      _redirectSubscription?.cancel();
      _redirectSubscription = links.uriLinkStream.listen(_eingang, onError: (e) {
        debugPrint('GptomAidlPlugin: Fehler beim Lauschen auf Redirects: $e');
      });
      _isListening = true;
    } catch (e) {
      debugPrint('GptomAidlPlugin: Fehler bei Initialisierung von AppLinks: $e');
    }
  }

  /// Eingehender App-Link: nur das eigene Scheme zählt. Groß-/Kleinschreibung
  /// ist egal – `Uri` liefert das Scheme immer klein, die App darf es aber
  /// z. B. als `MeineApp` registrieren.
  static void _eingang(Uri uri) {
    if (uri.scheme.toLowerCase() == _expectedScheme.toLowerCase()) {
      _dispatchRedirect(uri);
    }
  }

  /// Verteilt einen eingegangenen Redirect: an den passenden wartenden
  /// Aufruf, sonst in den Puffer.
  static void _dispatchRedirect(Uri uri) {
    // Rohstrom bleibt bestehen (Rückwärtskompatibilität für Mitleser).
    gptomRedirectStream.add(uri);

    for (final waiter in List<_RedirectWaiter>.of(_waiters)) {
      if (waiter.accepts(uri)) {
        _waiters.remove(waiter);
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete(uri);
          _verbrauchen(waiter.token);
          return;
        }
      }
    }

    final token = tokenFromRedirect(uri);
    final art = token == null ? null : _ausgegebeneTokens[token];
    if (art == _TokenArt.sonstige) {
      // Später Redirect von Status, Login, Logout, Passwortwechsel,
      // Kassenschnitt oder Belegabfrage: Er gehört zu keiner Zahlung und darf
      // nie als solche lesbar werden. Nur der Rohstrom führt ihn.
      return;
    }

    // Kein Wartender. Im Token-Modus gilt der Redirect nur als bestätigt,
    // wenn er das Token einer Zahlung trägt, die dieser Prozess gestartet hat
    // – ein gefälschter Link ohne oder mit erfundenem Token ergibt so nie
    // "bezahlt". Je Token höchstens ein bestätigter Eintrag: eine Kopie
    // desselben Redirects bliebe sonst doppelt verbuchbar.
    final bestaetigt = !GptomSecurityConfig.current.redirectTokenIOS ||
        (art == _TokenArt.zahlung &&
            !_pendingRedirects.any(
                (p) => p.isVerified && tokenFromRedirect(p.uri) == token));
    _pendingRedirects
        .add(GptomPendingRedirect(uri, DateTime.now(), isVerified: bestaetigt));
    while (_pendingRedirects.length > maxPendingRedirects) {
      // Erst die unbestätigten: eine Flut gefälschter Links darf eine echte,
      // noch nicht abgeholte Zahlung nicht aus dem Puffer drängen.
      final unbestaetigt = _pendingRedirects.indexWhere((p) => !p.isVerified);
      _pendingRedirects.removeAt(unbestaetigt >= 0 ? unbestaetigt : 0);
    }
  }

  /// Nur für Tests: verarbeitet [uri] wie einen eingehenden App-Link
  /// (inklusive Scheme-Filter).
  @visibleForTesting
  static void debugHandleRedirect(Uri uri) => _eingang(uri);

  /// Nur für Tests: ersetzt `launchUrl` und hebt die iOS-Prüfung auf, damit
  /// der komplette Redirect-Weg ohne Gerät prüfbar ist.
  @visibleForTesting
  static Future<bool> Function(Uri uri)? debugLauncher;

  /// Läuft der iOS-Weg (echtes iOS oder Test-Ersatz)?
  static bool get isActive => Platform.isIOS || debugLauncher != null;

  /// Nur für Tests: setzt den Zustand zurück. Leert auch die ausgegebenen
  /// Tokens und simuliert damit einen Kaltstart.
  @visibleForTesting
  static void debugReset() {
    debugLauncher = null;
    _waiters.clear();
    _pendingRedirects.clear();
    _ausgegebeneTokens.clear();
    _verbrauchteTokens.clear();
  }

  static Future<bool> _launch(Uri uri) {
    final launcher = debugLauncher;
    if (launcher != null) return launcher(uri);
    return launchUrl(uri);
  }

  /// Öffnet GP tom mit der URL aus [bauen] und wartet auf den zugehörigen
  /// Redirect. [bauen] bekommt die Redirect-URL für diesen Aufruf.
  ///
  /// Token-Modus (Standard): ohne [token] vergibt die Methode ein eigenes.
  /// Das Token wird vor dem Öffnen als ausgegeben gemerkt; angenommen wird
  /// nur ein Redirect mit genau diesem Token. Altmodus
  /// (`redirectTokenIOS = false`): kein Token, Zuordnung über
  /// [originReferenceNum] wie bisher.
  ///
  /// `redirect == null && !cannotOpen` heißt Timeout. Ein später
  /// eintreffender Redirect landet dann nur bei [zahlung] (Verkauf, Storno,
  /// Rückerstattung) bestätigt im Puffer ([pendingRedirect]). Bei allen
  /// anderen Aufrufen (Status, Login, Kassenschnitt, Belegabfrage, …) geht
  /// er nur in den Rohstrom: Er darf nie als Zahlung lesbar werden.
  ///
  /// Die geöffnete URL kann Zugangsdaten enthalten und erscheint deshalb in
  /// keiner Fehlermeldung und keinem Log. Ob der iOS-Weg aktiv ist
  /// ([isActive]), prüft der Aufrufer.
  static Future<({Uri? redirect, bool cannotOpen})> roundtrip(
    Uri Function(String redirectUrl) bauen, {
    required Duration timeout,
    String? token,
    String? originReferenceNum,
    bool zahlung = false,
  }) async {
    if (token != null && !_tokenMuster.hasMatch(token)) {
      throw ArgumentError(
        'Token muss aus 32 Hex-Zeichen (klein) bestehen – mit neueVorgangsId() erzeugen.',
        'token',
      );
    }
    final vorgangsToken = GptomSecurityConfig.current.redirectTokenIOS
        ? (token ?? neueVorgangsId())
        : null;
    final uri = bauen(redirectUrlFuer(vorgangsToken));
    if (vorgangsToken != null) {
      _merkeToken(vorgangsToken, zahlung ? _TokenArt.zahlung : _TokenArt.sonstige);
    }

    // Vor dem Öffnen anmelden, damit kein Redirect verpasst wird.
    final waiter = _RedirectWaiter(
      token: vorgangsToken,
      expectedReference: originReferenceNum,
    );
    _waiters.add(waiter);

    bool geoeffnet;
    try {
      geoeffnet = await _launch(uri);
    } catch (_) {
      // Die Ausnahme kann die URL enthalten – nicht weiterreichen.
      geoeffnet = false;
    }
    if (!geoeffnet) {
      _waiters.remove(waiter);
      return (redirect: null, cannotOpen: true);
    }

    try {
      final redirect = await waiter.completer.future.timeout(timeout);
      return (redirect: redirect, cannotOpen: false);
    } on TimeoutException {
      // Der Wächter gibt auf; ein später eintreffender Redirect landet damit
      // im Puffer und ist über pendingRedirect() abholbar.
      _waiters.remove(waiter);
      return (redirect: null, cannotOpen: false);
    }
  }

  /// Redirects, die keinem wartenden Aufruf zugeordnet werden konnten –
  /// älteste zuerst.
  static List<GptomPendingRedirect> get pendingRedirects =>
      List<GptomPendingRedirect>.unmodifiable(_pendingRedirects);

  /// Holt einen unzugeordneten Redirect ab und entfernt ihn aus dem Puffer.
  ///
  /// Mit [requestId] den Redirect mit genau diesem Token. Er gilt als
  /// bestätigt ([GptomPendingRedirect.isVerified]), auch nach einem
  /// Kaltstart. Das ist nur sicher, weil [requestId] aus dem eigenen Speicher
  /// der App stammt (vor dem Aufruf gesichert, eine Kennung je
  /// Zahlungsversuch, nie wiederverwendet) – nie aus einem Redirect oder
  /// einem Ergebnis. Unbestätigte Einträge und ihre Ergebnisse geben das
  /// Token deshalb gar nicht erst heraus. Wurde der Redirect zu [requestId]
  /// in diesem Prozess schon beantwortet oder abgeholt, ist ein weiterer eine
  /// Kopie und bleibt unbestätigt. [originReferenceNum] wird dann nicht
  /// beachtet.
  ///
  /// Sonst mit [originReferenceNum] gezielt den Redirect zu einer gemerkten
  /// Zahlung, ohne Angabe irgendeinen. In beiden Fällen zuerst den ältesten
  /// bestätigten, erst wenn es keinen gibt den ältesten unbestätigten; so
  /// verdeckt eine Fälschung nie die echte Antwort. `isVerified` bleibt
  /// dabei, wie es beim Eingang festgestellt wurde. Passt nichts, bleibt der
  /// Puffer unverändert und es kommt `null`.
  static GptomPendingRedirect? pendingRedirect({
    String? originReferenceNum,
    String? requestId,
  }) {
    if (_pendingRedirects.isEmpty) return null;
    if (requestId != null) {
      // Das rohe Token aus dem Pfad: ein unbestätigter Eintrag gibt es über
      // seinen `requestId`-Getter nicht heraus.
      final i = _aeltesterPassender((p) => tokenFromRedirect(p.uri) == requestId);
      if (i < 0) return null;
      final offen = _pendingRedirects.removeAt(i);
      final bestaetigt = !_verbrauchteTokens.contains(requestId);
      if (bestaetigt) _verbrauchen(requestId);
      return GptomPendingRedirect(offen.uri, offen.receivedAt, isVerified: bestaetigt);
    }
    final i = _aeltesterPassender((p) =>
        originReferenceNum == null || p.originReferenceNum == originReferenceNum);
    if (i < 0) return null;
    final offen = _pendingRedirects.removeAt(i);
    if (offen.isVerified) _verbrauchen(tokenFromRedirect(offen.uri));
    return offen;
  }

  /// Index des ältesten bestätigten Eintrags, auf den [passt] zutrifft; gibt
  /// es keinen, des ältesten unbestätigten. `-1`, wenn nichts passt.
  static int _aeltesterPassender(bool Function(GptomPendingRedirect) passt) {
    final bestaetigt =
        _pendingRedirects.indexWhere((p) => p.isVerified && passt(p));
    return bestaetigt >= 0 ? bestaetigt : _pendingRedirects.indexWhere(passt);
  }

  /// Leert den Puffer (z. B. nachdem die App alle offenen Zahlungen geklärt hat).
  static void clearPendingRedirects() => _pendingRedirects.clear();

  /// Standard-Timeouts für den Redirect aus GP tom zurück in die App.
  ///
  /// Eine Kartenzahlung dauert im Feld im Mittel rund 15 Sekunden, in
  /// Einzelfällen aber über zwei Minuten (Karte suchen, PIN-Eingabe,
  /// Terminal-Verbindung). Läuft der Timeout vorher ab, meldet das Plugin
  /// -1003, während GP tom die Zahlung zu Ende führt: Die Karte wird belastet,
  /// die aufrufende App erfährt davon nichts. Der Wert ist deshalb bewusst
  /// großzügig bemessen.
  static const Duration defaultTransactionRedirectTimeout = Duration(minutes: 3);
  static const Duration defaultCloseBatchRedirectTimeout = Duration(seconds: 15);

  /// Baut die URL für gptom://batch/close (Werte laut iOS-URL-Scheme-Doku).
  @visibleForTesting
  static Uri buildCloseBatchUri({
    required String redirectUrl,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
  }) {
    return Uri(
      scheme: 'gptom',
      host: 'batch',
      path: 'close',
      queryParameters: {
        if (clientID != null) 'clientID': clientID,
        'redirectUrl': redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.iosKey,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
      },
    );
  }

  static Future<Batch> closeBatchIOS({
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    Duration? redirectTimeout,
  }) async {
    if (!isActive) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'closeBatchIOS is not supported on Android',
      );
    }

    // Eigenes Token (Token-Modus); der Kassenschnitt trägt keine Referenz,
    // nimmt im Altmodus also den nächsten Redirect.
    final antwort = await roundtrip(
      (redirectUrl) => buildCloseBatchUri(
        redirectUrl: redirectUrl,
        clientID: clientID,
        printByPaymentApp: printByPaymentApp,
        preferableReceiptType: preferableReceiptType,
        clientPhone: clientPhone,
        clientEmail: clientEmail,
      ),
      timeout: redirectTimeout ?? defaultCloseBatchRedirectTimeout,
    );

    if (antwort.cannotOpen) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'Konnte GP tom nicht öffnen',
      );
    }

    final redirectedUri = antwort.redirect;
    if (redirectedUri == null) {
      throw Exception('Kein Redirect erhalten oder Timeout');
    }
    try {
      return batchFromRedirect(redirectedUri);
    } catch (_) {
      // Wie bisher: ein Redirect ohne lesbaren Batch meldet dieselbe Ausnahme.
      throw Exception('Kein Redirect erhalten oder Timeout');
    }
  }

  /// Parst den Batch aus dem Redirect von gptom://batch/close.
  @visibleForTesting
  static Batch batchFromRedirect(Uri redirectedUri) {
    final batchRaw = redirectedUri.queryParameters['batch'];
    if (batchRaw == null) {
      throw Exception('Kein Batch im Redirect enthalten');
    }
    return Batch.fromQuery(batchRaw);
  }

  /// Status-Wert, mit dem GP tom im Redirect einen erfolgreichen Abschluss
  /// meldet (query["status"] = TASK_STATUS). Wird nur gebraucht, wenn KEIN
  /// `receipt` im Redirect steckt – dann ist der Status die einzige
  /// verlässliche Information darüber, ob die Karte belastet wurde. Bewusst
  /// nur der eindeutig belegte Wert: ein falsch als Erfolg gewerteter Status
  /// würde eine nicht kassierte Zahlung als Beleg aufzeichnen.
  static const Set<String> _completedStatuses = {'COMPLETED'};

  /// Abbruch durch Kassier oder Kunde. Die Doku "Transaction Sales (iOS)"
  /// nennt für TASK_STATUS genau COMPLETED, CANCELED und ERROR; die
  /// britische Schreibweise CANCELLED taucht in anderen Teilen derselben
  /// Doku auf und wird deshalb ebenfalls akzeptiert. Alles andere gilt
  /// NICHT als Abbruch – lieber "unklar" melden als eine belastete Karte
  /// als Abbruch verbuchen.
  static const Set<String> _cancelledStatuses = {'CANCELED', 'CANCELLED'};

  static bool _statusIsCompleted(String? status) =>
      status != null && _completedStatuses.contains(status.toUpperCase());

  static bool _statusIsCancelled(String? status) =>
      status != null && _cancelledStatuses.contains(status.toUpperCase());

  /// Receipt-Beträge liefert GPTom als Euro-Dezimalwerte (z. B. "4.35").
  /// Punkt oder Komma, ohne Fließkomma-Rechnung.
  static int? _centsFromReceipt(dynamic value) => centsFromDecimal(value);

  /// GP tom liefert `result` teils als Zahl, teils als String.
  static int? _intFromReceipt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value.toString());
  }

  static String? _stringFromReceipt(dynamic value) {
    if (value == null) return null;
    final text = value.toString();
    return text.isEmpty ? null : text;
  }

  static RequestResult _pluginFehler(
    int code,
    String errorCode,
    String message, {
    String? requestId,
  }) {
    return RequestResult(
      result: code,
      responseMessage: message,
      error: ErrorInfo(errorCode: errorCode, result: code),
      requestId: requestId,
    );
  }

  /// Prüft eine von der App vorgegebene Vorgangskennung oder erzeugt eine.
  static String _vorgangsIdPruefen(String? requestId) {
    if (requestId == null) return neueVorgangsId();
    if (!_tokenMuster.hasMatch(requestId)) {
      // Der Wert selbst bleibt aus der Meldung heraus.
      throw ArgumentError(
        'requestId muss aus 32 Hex-Zeichen (klein) bestehen – mit neueVorgangsId() erzeugen.',
        'requestId',
      );
    }
    return requestId;
  }

  /// Referenz aus einem Redirect. GP tom gibt die mitgegebene
  /// `originReferenceNum` als `referenceNumber` zurück (Doku "Transaction
  /// Sales (iOS)", Antwort-Tabelle); je nach App-Version steht sie im Query
  /// oder im Beleg. Fehlt sie ganz, liefert die Methode `null` – der
  /// Redirect wird dann wie bisher dem wartenden Aufruf zugeschlagen.
  static String? referenceFromRedirect(Uri uri) {
    final query = uri.queryParameters;
    final direct = query['referenceNumber'] ?? query['originReferenceNum'];
    if (direct != null && direct.isNotEmpty) return direct;

    final receiptRaw = query['receipt'];
    if (receiptRaw == null) return null;
    try {
      final decoded = jsonDecode(receiptRaw);
      if (decoded is Map) {
        final reference = decoded['referenceNumber'] ?? decoded['originReferenceNum'];
        if (reference != null && reference.toString().isNotEmpty) {
          return reference.toString();
        }
      }
    } catch (_) {
      // Kaputter Beleg: keine Referenz, aber auch kein Fehler an dieser Stelle.
    }
    return null;
  }

  /// Baut die URL für gptom://transaction/create (Sale).
  @visibleForTesting
  static Uri buildCreateTransactionUri({
    required int amountCents,
    required String redirectUrl,
    required TransactionMethode transactionMethode,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    int? tipAmountCents,
    bool tipCollect = false,
    String? requestId,
  }) {
    return Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'create',
      queryParameters: {
        // GPTom erwartet den Betrag in Cent (*100-Format)
        'amount': amountCents.toString(),
        if (clientID != null) 'clientID': clientID,
        if (originReferenceNum != null) 'originReferenceNum': originReferenceNum,
        if (requestId != null) 'requestID': requestId,
        'redirectUrl': redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.iosKey,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
        if (tipAmountCents != null) 'tipAmount': tipAmountCents.toString(),
        'tipCollect': tipCollect.toString(),
        'transactionType': transactionMethode.text,
      },
    );
  }

  /// Baut die URL für gptom://transaction/cancel (Void).
  @visibleForTesting
  static Uri buildCancelTransactionUri({
    required String amsID,
    required String redirectUrl,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    String? requestId,
  }) {
    return Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'cancel',
      queryParameters: {
        'amsID': amsID,
        if (clientID != null) 'clientID': clientID,
        if (requestId != null) 'requestID': requestId,
        'redirectUrl': redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.iosKey,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
      },
    );
  }

  /// Gemeinsames Receipt-Parsing für create/cancel-Redirects.
  /// Bei create ist die "eigene" Transaktions-ID die amsID, bei cancel die
  /// transactionID (und die amsID landet in externalTransactionID).
  ///
  /// Alles hier ist Fremd-Input: Kein Schritt darf werfen, und die
  /// Ausgänge müssen unterscheidbar bleiben (siehe [GptomResultCode]).
  /// [requestId] steht in jedem Ergebnis, auch in den Fehlern.
  /// [art] `null` (Belegabfrage): die Art des Vorgangs ist nicht bekannt,
  /// `transactionType` bleibt leer, die Kennung ist die amsID.
  static RequestResult _requestResultFromReceipt(
    Uri redirectedUri, {
    required bool printByPaymentApp,
    required TransactionType? art,
    String? originReferenceNum,
    String? requestId,
  }) {
    // Beim Storno ist die "eigene" Kennung die transactionID, sonst die amsID.
    final isCancel = art == TransactionType.voidSell;
    final query = redirectedUri.queryParameters;
    final receiptRaw = query['receipt'];
    final status = query['status'];

    if (receiptRaw == null) {
      // GP tom liefert bei erfolgreichem Abschluss gelegentlich keinen
      // `receipt`-Parameter, meldet den Erfolg aber über `status`
      // (COMPLETED). Diesen Fall NICHT verwerfen – sonst gilt eine
      // tatsächlich belastete Karte als abgebrochen und der Umsatz fehlt in
      // der Aufzeichnung. Ohne Beleg fehlen die Kartendetails; als Kennung
      // dient dann die amsID, ersatzweise die eigene Referenz.
      if (_statusIsCompleted(status)) {
        return RequestResult(
          result: GptomResultCode.success,
          responseMessage: status,
          amsID: query['amsID'],
          transactionId: query['amsID'] ?? originReferenceNum,
          externalTransactionID: query['transactionID'],
          printByPaymentApp: printByPaymentApp,
          transactionType: art,
          requestId: requestId,
        );
      }
      if (_statusIsCancelled(status)) {
        return _pluginFehler(
          GptomResultCode.cancelled,
          GptomErrorCode.cancelled,
          status!,
          requestId: requestId,
        );
      }
      // Kein Beleg und kein Erfolgs-Status → unklar/kein Abschluss. Den
      // Status durchreichen, damit die App den echten Grund sieht.
      return _pluginFehler(
        GptomResultCode.noReceipt,
        GptomErrorCode.noReceipt,
        status ?? 'Kein Receipt enthalten',
        requestId: requestId,
      );
    }

    final dynamic decoded;
    try {
      decoded = jsonDecode(receiptRaw);
    } catch (_) {
      // Ein unlesbarer Beleg ist KEIN Zeitablauf: die Karte kann belastet
      // sein, aber der Grund ist ein anderer.
      return _pluginFehler(
        GptomResultCode.parseError,
        GptomErrorCode.parseError,
        'Beleg im Redirect nicht lesbar',
        requestId: requestId,
      );
    }
    if (decoded is! Map) {
      return _pluginFehler(
        GptomResultCode.parseError,
        GptomErrorCode.parseError,
        'Beleg im Redirect hat ein unerwartetes Format',
        requestId: requestId,
      );
    }
    final receipt = Map<String, dynamic>.from(decoded);

    String? cardNumber = _stringFromReceipt(receipt['cardNumber']);
    if (cardNumber != null && cardNumber.length == 4) {
      cardNumber = '**** **** **** $cardNumber';
    }

    String? date, time;
    final rohesDatum = receipt['date'];
    if (rohesDatum != null) {
      // Ungültiges Datum: Felder leer lassen statt zu werfen – der Rest des
      // Belegs (und vor allem das Ergebnis) bleibt brauchbar.
      final dateTime = DateTime.tryParse(rohesDatum.toString());
      if (dateTime != null) {
        date = '${dateTime.day.toString().padLeft(2, '0')}${dateTime.month.toString().padLeft(2, '0')}${dateTime.year.toString().substring(2)}';
        time = '${dateTime.hour.toString().padLeft(2, '0')}${dateTime.minute.toString().padLeft(2, '0')}${dateTime.second.toString().padLeft(2, '0')}';
      }
    }

    var ergebnis = _intFromReceipt(receipt['result']);
    if (ergebnis == null) {
      // Beleg ohne `result`: der Status ist dann die einzige Aussage.
      if (_statusIsCompleted(status)) {
        ergebnis = GptomResultCode.success;
      } else if (_statusIsCancelled(status)) {
        return _pluginFehler(
          GptomResultCode.cancelled,
          GptomErrorCode.cancelled,
          status!,
          requestId: requestId,
        );
      } else {
        return _pluginFehler(
          GptomResultCode.parseError,
          GptomErrorCode.parseError,
          'Beleg im Redirect ohne Ergebnis',
          requestId: requestId,
        );
      }
    }

    ErrorInfo? fehler;
    if (ergebnis != GptomResultCode.success) {
      // Abgelehnt oder abgebrochen: der Code des Terminals bleibt erhalten,
      // die Fehlerkennung sagt der App, wie sie den Fall behandeln soll.
      fehler = ErrorInfo(
        errorCode: _statusIsCancelled(status)
            ? GptomErrorCode.cancelled
            : (_stringFromReceipt(receipt['errorCode']) ?? GptomErrorCode.declined),
        result: ergebnis,
      );
    }

    return RequestResult(
      result: ergebnis,
      transactionId: _stringFromReceipt(
          isCancel ? receipt['transactionID'] : receipt['amsID']),
      amountCents: _centsFromReceipt(receipt['amount']),
      tipAmountCents: _centsFromReceipt(receipt['tipAmount']),
      totalAmountCents: _centsFromReceipt(receipt['totalAmount']),
      batchNumber: _stringFromReceipt(receipt['batchNumber']),
      approvedCode: _stringFromReceipt(receipt['authorizationCode']),
      emvAppLable: _stringFromReceipt(receipt['emvAppLabel']),
      emvAid: _stringFromReceipt(receipt['emvAid']),
      responseMessage: status,
      sequenceNumber: _stringFromReceipt(receipt['sequenceNumber']),
      terminalID: _stringFromReceipt(receipt['terminalID']),
      merchantID: _stringFromReceipt(receipt['merchantID']),
      cardNumber: cardNumber,
      cardProduct: _stringFromReceipt(receipt['cardType']),
      currencyCode: _stringFromReceipt(receipt['currencyCode']),
      pinOk: receipt['pinOk'] == true,
      printByPaymentApp: printByPaymentApp,
      externalTransactionID: _stringFromReceipt(
          isCancel ? receipt['amsID'] : receipt['transactionID']),
      date: date,
      cardDataEntry: _stringFromReceipt(receipt['cardEntryMode']),
      amsID: _stringFromReceipt(receipt['amsID']),
      time: time,
      transactionType: art,
      requestId: requestId,
      error: fehler,
    );
  }

  /// Parst das Ergebnis aus dem Redirect von gptom://transaction/create.
  @visibleForTesting
  static RequestResult requestResultFromCreateRedirect(
    Uri redirectedUri, {
    required bool printByPaymentApp,
    String? originReferenceNum,
    String? requestId,
  }) {
    return _requestResultFromReceipt(
      redirectedUri,
      printByPaymentApp: printByPaymentApp,
      art: TransactionType.sell,
      originReferenceNum: originReferenceNum,
      requestId: requestId,
    );
  }

  /// Parst das Ergebnis aus dem Redirect von gptom://transaction/cancel.
  @visibleForTesting
  static RequestResult requestResultFromCancelRedirect(
    Uri redirectedUri, {
    required bool printByPaymentApp,
    String? originReferenceNum,
    String? requestId,
  }) {
    return _requestResultFromReceipt(
      redirectedUri,
      printByPaymentApp: printByPaymentApp,
      art: TransactionType.voidSell,
      originReferenceNum: originReferenceNum,
      requestId: requestId,
    );
  }

  /// Parst das Ergebnis aus dem Redirect von gptom://transaction/refund.
  @visibleForTesting
  static RequestResult requestResultFromRefundRedirect(
    Uri redirectedUri, {
    required bool printByPaymentApp,
    String? originReferenceNum,
    String? requestId,
  }) {
    return _requestResultFromReceipt(
      redirectedUri,
      printByPaymentApp: printByPaymentApp,
      art: TransactionType.refund,
      originReferenceNum: originReferenceNum,
      requestId: requestId,
    );
  }

  /// Parst das Ergebnis aus dem Redirect von gptom://transaction/detail.
  ///
  /// Anders als beim Verkauf zählt hier nur ein Beleg: Ohne `receipt` ist
  /// das Ergebnis [GptomResultCode.noReceipt], auch bei `status=COMPLETED`
  /// (die Abfrage ist gelungen, über die Zahlung sagt das nichts). Der
  /// `error`-Wert von GP tom (z. B. „nicht gefunden“) steht dann in
  /// `error.errorCode`, der Status in `responseMessage`.
  ///
  /// Mit Beleg wird er wie beim Verkauf gelesen, aber ohne `transactionType`:
  /// Das gleichnamige Feld im Beleg ist die Zahlungsart, nicht Verkauf oder
  /// Storno.
  @visibleForTesting
  static RequestResult requestResultFromDetailRedirect(
    Uri redirectedUri, {
    String? requestId,
  }) {
    final query = redirectedUri.queryParameters;
    if (query['receipt'] == null) {
      final gpTomFehler = query['error'];
      return _pluginFehler(
        GptomResultCode.noReceipt,
        gpTomFehler != null && gpTomFehler.isNotEmpty
            ? gpTomFehler
            : GptomErrorCode.noReceipt,
        query['status'] ?? 'Kein Receipt enthalten',
        requestId: requestId,
      );
    }
    return _requestResultFromReceipt(
      redirectedUri,
      printByPaymentApp: false,
      art: null,
      requestId: requestId,
    );
  }

  /// Baut die URL für gptom://transaction/refund.
  @visibleForTesting
  static Uri buildRefundUri({
    required int amountCents,
    required String redirectUrl,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    String? requestId,
  }) {
    return Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'refund',
      queryParameters: {
        'amount': amountCents.toString(),
        if (clientID != null) 'clientID': clientID,
        if (originReferenceNum != null) 'originReferenceNum': originReferenceNum,
        if (requestId != null) 'requestID': requestId,
        'redirectUrl': redirectUrl,
        'printByPaymentApp': printByPaymentApp.toString(),
        if (preferableReceiptType != null) 'preferableReceiptType': preferableReceiptType.iosKey,
        if (clientPhone != null) 'clientPhone': clientPhone,
        if (clientEmail != null) 'clientEmail': clientEmail,
      },
    );
  }

  /// Baut die URL für gptom://transaction/detail. Mindestens [amsID] oder
  /// [requestId] muss gesetzt sein, sonst [ArgumentError].
  @visibleForTesting
  static Uri buildTransactionDetailUri({
    String? amsID,
    String? requestId,
    String? clientID,
    required String redirectUrl,
  }) {
    if (amsID == null && requestId == null) {
      throw ArgumentError('amsID oder requestId angeben.');
    }
    return Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'detail',
      queryParameters: {
        if (amsID != null) 'amsID': amsID,
        if (requestId != null) 'requestID': requestId,
        if (clientID != null) 'clientID': clientID,
        'redirectUrl': redirectUrl,
      },
    );
  }

  /// Rückerstattung über `gptom://transaction/refund`. [requestId] wie bei
  /// [createTransactionIOS]; das Ergebnis trägt sie immer.
  static Future<RequestResult> refundTransactionIOS({
    required int amountCents,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    String? requestId,
    Duration? redirectTimeout,
  }) async {
    final vorgangsId = _vorgangsIdPruefen(requestId);
    if (!isActive) {
      return RequestResult(result: GptomResultCode.exception, requestId: vorgangsId);
    }
    final sendeRequestId = GptomSecurityConfig.current.sendRequestIdIOS;

    final redirectedUri = await _oeffnenUndWarten(
      (redirectUrl) => buildRefundUri(
        amountCents: amountCents,
        redirectUrl: redirectUrl,
        originReferenceNum: originReferenceNum,
        clientID: clientID,
        printByPaymentApp: printByPaymentApp,
        preferableReceiptType: preferableReceiptType,
        clientPhone: clientPhone,
        clientEmail: clientEmail,
        requestId: sendeRequestId ? vorgangsId : null,
      ),
      vorgangsId: vorgangsId,
      originReferenceNum: originReferenceNum,
      timeout: redirectTimeout ?? defaultTransactionRedirectTimeout,
    );
    if (redirectedUri is RequestResult) return redirectedUri;

    return requestResultFromRefundRedirect(
      redirectedUri as Uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
      requestId: vorgangsId,
    );
  }

  /// Standard-Timeout der Belegabfrage (kein Kundenvorgang).
  static const Duration defaultTransactionDetailTimeout = Duration(seconds: 30);

  /// Fragt über `gptom://transaction/detail` den Beleg einer Transaktion ab,
  /// per [amsId] und/oder [requestId] (die vor dem Aufruf gespeicherte
  /// Vorgangskennung). Die Abfrage selbst läuft unter einem eigenen,
  /// frischen Token. Fehlen beide, wirft die Methode [ArgumentError], ebenso
  /// bei einer Abfrage nur per [requestId], wenn `sendRequestIdIOS` aus ist
  /// (dann geht keine `requestID` an GP tom) – jeweils vor dem Öffnen.
  ///
  /// Das Ergebnis liest den Beleg wie beim Verkauf, aber ohne
  /// `transactionType`. Ohne Beleg ist es [GptomResultCode.noReceipt], nie
  /// Erfolg (siehe [requestResultFromDetailRedirect]). Sein `requestId` ist
  /// die nachgeschlagene Kennung (der eigene Wert der App), sonst `null`.
  static Future<RequestResult> transactionDetailIOS({
    String? amsId,
    String? requestId,
    String? clientId,
    Duration? timeout,
  }) async {
    if (requestId != null) _vorgangsIdPruefen(requestId);
    if (amsId == null && requestId == null) {
      throw ArgumentError('amsId oder requestId angeben.');
    }
    final sendeRequestId = GptomSecurityConfig.current.sendRequestIdIOS;
    if (amsId == null && !sendeRequestId) {
      // Ohne requestID an GP tom bliebe die Abfrage leer – vor dem Öffnen
      // abbrechen statt GP tom mit einer unvollständigen URL aufzurufen.
      throw ArgumentError(
        'transactionDetailIOS: Abfrage per requestId braucht sendRequestIdIOS – amsId angeben',
      );
    }
    if (!isActive) {
      return RequestResult(result: GptomResultCode.exception, requestId: requestId);
    }

    final antwort = await roundtrip(
      (redirectUrl) => buildTransactionDetailUri(
        amsID: amsId,
        requestId: sendeRequestId ? requestId : null,
        clientID: clientId,
        redirectUrl: redirectUrl,
      ),
      timeout: timeout ?? defaultTransactionDetailTimeout,
    );
    final redirect = antwort.redirect;
    if (redirect == null) {
      if (antwort.cannotOpen) {
        return _pluginFehler(
          GptomResultCode.cannotOpen,
          GptomErrorCode.cannotOpen,
          'Konnte GP tom nicht öffnen',
          requestId: requestId,
        );
      }
      return _pluginFehler(
        GptomResultCode.timeout,
        GptomErrorCode.timeout,
        'Kein Redirect erhalten oder Timeout',
        requestId: requestId,
      );
    }
    return requestResultFromDetailRedirect(redirect, requestId: requestId);
  }

  /// Verkauf über `gptom://transaction/create`.
  ///
  /// [requestId] ist die Vorgangskennung (32 Hex-Zeichen, siehe
  /// [neueVorgangsId]), eine je Zahlungsversuch und nie wiederverwendet;
  /// ohne Angabe wird eine erzeugt. Sie ist im
  /// Token-Modus zugleich das Redirect-Token, geht bei `sendRequestIdIOS` als
  /// `requestID` an GP tom und steht in jedem Ergebnis, auch bei Fehlern und
  /// Timeout. Eine ungültige [requestId] wirft [ArgumentError].
  static Future<RequestResult> createTransactionIOS({
    required int amountCents,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    int? tipAmountCents,
    bool tipCollect = false,
    required TransactionMethode transactionMethode,
    Duration? redirectTimeout,
    String? requestId,
  }) async {
    final vorgangsId = _vorgangsIdPruefen(requestId);
    if (!isActive) {
      return RequestResult(result: GptomResultCode.exception, requestId: vorgangsId);
    }
    final sendeRequestId = GptomSecurityConfig.current.sendRequestIdIOS;

    final redirectedUri = await _oeffnenUndWarten(
      (redirectUrl) => buildCreateTransactionUri(
        amountCents: amountCents,
        redirectUrl: redirectUrl,
        transactionMethode: transactionMethode,
        originReferenceNum: originReferenceNum,
        clientID: clientID,
        printByPaymentApp: printByPaymentApp,
        preferableReceiptType: preferableReceiptType,
        clientPhone: clientPhone,
        clientEmail: clientEmail,
        tipAmountCents: tipAmountCents,
        tipCollect: tipCollect,
        requestId: sendeRequestId ? vorgangsId : null,
      ),
      vorgangsId: vorgangsId,
      originReferenceNum: originReferenceNum,
      timeout: redirectTimeout ?? defaultTransactionRedirectTimeout,
    );
    if (redirectedUri is RequestResult) return redirectedUri;

    return requestResultFromCreateRedirect(
      redirectedUri as Uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
      requestId: vorgangsId,
    );
  }

  /// Storno über `gptom://transaction/cancel`. [requestId] wie bei
  /// [createTransactionIOS].
  static Future<RequestResult> cancelTransactionIOS({
    required String amsID,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    Duration? redirectTimeout,
    String? requestId,
  }) async {
    final vorgangsId = _vorgangsIdPruefen(requestId);
    if (!isActive) {
      return RequestResult(result: GptomResultCode.exception, requestId: vorgangsId);
    }
    final sendeRequestId = GptomSecurityConfig.current.sendRequestIdIOS;

    final redirectedUri = await _oeffnenUndWarten(
      (redirectUrl) => buildCancelTransactionUri(
        amsID: amsID,
        redirectUrl: redirectUrl,
        clientID: clientID,
        printByPaymentApp: printByPaymentApp,
        preferableReceiptType: preferableReceiptType,
        clientPhone: clientPhone,
        clientEmail: clientEmail,
        requestId: sendeRequestId ? vorgangsId : null,
      ),
      vorgangsId: vorgangsId,
      originReferenceNum: originReferenceNum,
      timeout: redirectTimeout ?? defaultTransactionRedirectTimeout,
    );
    if (redirectedUri is RequestResult) return redirectedUri;

    return requestResultFromCancelRedirect(
      redirectedUri as Uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
      requestId: vorgangsId,
    );
  }

  /// Öffnet GP tom über [roundtrip] mit der Vorgangskennung als Token und
  /// wartet auf den zugehörigen Redirect.
  /// Liefert entweder den `Uri` des Redirects oder – wenn es dazu nicht kam –
  /// ein fertiges Fehler-[RequestResult] mit der Vorgangskennung.
  static Future<Object> _oeffnenUndWarten(
    Uri Function(String redirectUrl) bauen, {
    required String vorgangsId,
    required String? originReferenceNum,
    required Duration timeout,
  }) async {
    final antwort = await roundtrip(
      bauen,
      timeout: timeout,
      token: vorgangsId,
      originReferenceNum: originReferenceNum,
      zahlung: true,
    );
    final redirect = antwort.redirect;
    if (redirect != null) return redirect;

    if (antwort.cannotOpen) {
      return _pluginFehler(
        GptomResultCode.cannotOpen,
        GptomErrorCode.cannotOpen,
        'Konnte GP tom nicht öffnen',
        requestId: vorgangsId,
      );
    }
    // Zeitablauf: ein später eintreffender Redirect landet im Puffer und
    // ist über pendingRedirect() abholbar.
    return _pluginFehler(
      GptomResultCode.timeout,
      GptomErrorCode.timeout,
      'Kein Redirect erhalten oder Timeout',
      requestId: vorgangsId,
    );
  }
}
