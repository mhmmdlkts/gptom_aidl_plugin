import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gptom_aidl_plugin/gptom_result_code.dart';
import 'package:gptom_aidl_plugin/models/batch.dart';
import 'package:url_launcher/url_launcher.dart';
import 'enums/preferable_receipt_type.dart';
import 'enums/transaction_methode.dart';
import 'enums/transaction_type.dart';
import 'models/request_result.dart';

/// Ein Redirect aus GP tom, für den es keinen wartenden Aufruf gab –
/// typischerweise nach einem Kaltstart (iOS hat die Kasse beendet, während
/// GP tom vorn war) oder ein verspäteter Redirect einer früheren Zahlung.
///
/// Die App holt ihn mit [GptomAidlPluginIOS.pendingRedirect] ab und ordnet
/// ihn über [originReferenceNum] ihrer gemerkten Zahlung zu.
class GptomPendingRedirect {
  /// Der rohe Redirect, wie GP tom ihn geschickt hat.
  final Uri uri;

  /// Zeitpunkt des Eingangs (Gerätezeit).
  final DateTime receivedAt;

  GptomPendingRedirect(this.uri, this.receivedAt);

  /// Referenz aus dem Redirect (`referenceNumber` bzw. `originReferenceNum`),
  /// also genau der Wert, den die App bei `sell` mitgegeben hat.
  String? get originReferenceNum => GptomAidlPluginIOS.referenceFromRedirect(uri);

  /// `TASK_STATUS` aus dem Redirect (COMPLETED, CANCELED, ERROR).
  String? get status => uri.queryParameters['status'];

  /// Liest den Redirect als Ergebnis eines Verkaufs.
  RequestResult asSellResult({bool printByPaymentApp = false}) {
    return GptomAidlPluginIOS.requestResultFromCreateRedirect(
      uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
    );
  }

  /// Liest den Redirect als Ergebnis eines Stornos.
  RequestResult asVoidResult({bool printByPaymentApp = false}) {
    return GptomAidlPluginIOS.requestResultFromCancelRedirect(
      uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
    );
  }

  @override
  String toString() =>
      'GptomPendingRedirect(originReferenceNum=$originReferenceNum, '
      'status=$status, receivedAt=$receivedAt)';
}

/// Wartet auf den Redirect einer bestimmten Zahlung.
class _RedirectWaiter {
  final String? expectedReference;
  final Completer<Uri> completer = Completer<Uri>();

  _RedirectWaiter(this.expectedReference);

  /// Ein Redirect ohne erkennbare Referenz wird angenommen – GP tom liefert
  /// die Referenz nur zurück, wenn sie mitgegeben wurde, und ältere
  /// App-Versionen kennen das Feld nicht.
  bool accepts(String? reference) =>
      expectedReference == null || reference == null || reference == expectedReference;
}

class GptomAidlPluginIOS {

  /// Roher Strom aller Redirects auf das eigene App-Scheme.
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

  /// Die Redirect-URL, die GP tom mitgegeben wird.
  @visibleForTesting
  static String get redirectUrl => _redirectUrl;

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
      _redirectSubscription = links.uriLinkStream.listen((Uri uri) {
        if (uri.scheme == _expectedScheme) {
          _dispatchRedirect(uri);
        }
      }, onError: (e) {
        debugPrint('GptomAidlPlugin: Fehler beim Lauschen auf Redirects: $e');
      });
      _isListening = true;
    } catch (e) {
      debugPrint('GptomAidlPlugin: Fehler bei Initialisierung von AppLinks: $e');
    }
  }

  /// Verteilt einen eingegangenen Redirect: an den passenden wartenden
  /// Aufruf, sonst in den Puffer.
  static void _dispatchRedirect(Uri uri) {
    // Rohstrom bleibt bestehen (Rückwärtskompatibilität für Mitleser).
    gptomRedirectStream.add(uri);

    final reference = referenceFromRedirect(uri);
    for (final waiter in List<_RedirectWaiter>.of(_waiters)) {
      if (waiter.accepts(reference)) {
        _waiters.remove(waiter);
        if (!waiter.completer.isCompleted) {
          waiter.completer.complete(uri);
          return;
        }
      }
    }

    _pendingRedirects.add(GptomPendingRedirect(uri, DateTime.now()));
    while (_pendingRedirects.length > maxPendingRedirects) {
      _pendingRedirects.removeAt(0);
    }
  }

  @visibleForTesting
  static void debugHandleRedirect(Uri uri) => _dispatchRedirect(uri);

  /// Nur für Tests: ersetzt `launchUrl` und hebt die iOS-Prüfung auf, damit
  /// der komplette Redirect-Weg ohne Gerät prüfbar ist.
  @visibleForTesting
  static Future<bool> Function(Uri uri)? debugLauncher;

  /// Läuft der iOS-Weg (echtes iOS oder Test-Ersatz)?
  static bool get isActive => Platform.isIOS || debugLauncher != null;

  @visibleForTesting
  static void debugReset() {
    debugLauncher = null;
    _waiters.clear();
    _pendingRedirects.clear();
  }

  static Future<bool> _launch(Uri uri) {
    final launcher = debugLauncher;
    if (launcher != null) return launcher(uri);
    return launchUrl(uri);
  }

  /// Redirects, die keinem wartenden Aufruf zugeordnet werden konnten –
  /// älteste zuerst.
  static List<GptomPendingRedirect> get pendingRedirects =>
      List<GptomPendingRedirect>.unmodifiable(_pendingRedirects);

  /// Holt einen unzugeordneten Redirect ab und entfernt ihn aus dem Puffer.
  ///
  /// Mit [originReferenceNum] gezielt den Redirect zu einer gemerkten
  /// Zahlung; ohne Angabe den ältesten. Passt nichts, bleibt der Puffer
  /// unverändert und es kommt `null`.
  static GptomPendingRedirect? pendingRedirect({String? originReferenceNum}) {
    if (_pendingRedirects.isEmpty) return null;
    if (originReferenceNum == null) {
      return _pendingRedirects.removeAt(0);
    }
    for (var i = 0; i < _pendingRedirects.length; i++) {
      if (_pendingRedirects[i].originReferenceNum == originReferenceNum) {
        return _pendingRedirects.removeAt(i);
      }
    }
    return null;
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

    final uri = buildCloseBatchUri(
      redirectUrl: _redirectUrl,
      clientID: clientID,
      printByPaymentApp: printByPaymentApp,
      preferableReceiptType: preferableReceiptType,
      clientPhone: clientPhone,
      clientEmail: clientEmail,
    );

    // Vor dem Öffnen anmelden, damit kein Redirect verpasst wird. Der
    // Kassenschnitt trägt keine Referenz, nimmt also den nächsten Redirect.
    final waiter = _RedirectWaiter(null);
    _waiters.add(waiter);

    bool success;
    try {
      success = await _launch(uri);
    } catch (e) {
      _waiters.remove(waiter);
      throw PlatformException(
        code: 'PlatformError',
        message: 'Konnte GP tom nicht öffnen',
      );
    }

    if (!success) {
      _waiters.remove(waiter);
      throw PlatformException(
        code: 'PlatformError',
        message: 'Konnte GP tom nicht öffnen',
      );
    }

    try {
      final redirectedUri = await waiter.completer.future
          .timeout(redirectTimeout ?? defaultCloseBatchRedirectTimeout);
      return batchFromRedirect(redirectedUri);
    } catch (e) {
      _waiters.remove(waiter);
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
  static int? _centsFromReceipt(dynamic value) {
    if (value == null) return null;
    final parsed = double.tryParse(value.toString());
    if (parsed == null) return null;
    return (parsed * 100).round();
  }

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

  static RequestResult _pluginFehler(int code, String errorCode, String message) {
    return RequestResult(
      result: code,
      responseMessage: message,
      error: ErrorInfo(errorCode: errorCode, result: code),
    );
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
  }) {
    return Uri(
      scheme: 'gptom',
      host: 'transaction',
      path: 'cancel',
      queryParameters: {
        'amsID': amsID,
        if (clientID != null) 'clientID': clientID,
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
  static RequestResult _requestResultFromReceipt(
    Uri redirectedUri, {
    required bool printByPaymentApp,
    required bool isCancel,
    String? originReferenceNum,
  }) {
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
          transactionType:
              isCancel ? TransactionType.voidSell : TransactionType.sell,
        );
      }
      if (_statusIsCancelled(status)) {
        return _pluginFehler(
          GptomResultCode.cancelled,
          GptomErrorCode.cancelled,
          status!,
        );
      }
      // Kein Beleg und kein Erfolgs-Status → unklar/kein Abschluss. Den
      // Status durchreichen, damit die App den echten Grund sieht.
      return _pluginFehler(
        GptomResultCode.noReceipt,
        GptomErrorCode.noReceipt,
        status ?? 'Kein Receipt enthalten',
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
      );
    }
    if (decoded is! Map) {
      return _pluginFehler(
        GptomResultCode.parseError,
        GptomErrorCode.parseError,
        'Beleg im Redirect hat ein unerwartetes Format',
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
        );
      } else {
        return _pluginFehler(
          GptomResultCode.parseError,
          GptomErrorCode.parseError,
          'Beleg im Redirect ohne Ergebnis',
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
      transactionType: isCancel ? TransactionType.voidSell : TransactionType.sell,
      error: fehler,
    );
  }

  /// Parst das Ergebnis aus dem Redirect von gptom://transaction/create.
  @visibleForTesting
  static RequestResult requestResultFromCreateRedirect(
    Uri redirectedUri, {
    required bool printByPaymentApp,
    String? originReferenceNum,
  }) {
    return _requestResultFromReceipt(
      redirectedUri,
      printByPaymentApp: printByPaymentApp,
      isCancel: false,
      originReferenceNum: originReferenceNum,
    );
  }

  /// Parst das Ergebnis aus dem Redirect von gptom://transaction/cancel.
  @visibleForTesting
  static RequestResult requestResultFromCancelRedirect(
    Uri redirectedUri, {
    required bool printByPaymentApp,
    String? originReferenceNum,
  }) {
    return _requestResultFromReceipt(
      redirectedUri,
      printByPaymentApp: printByPaymentApp,
      isCancel: true,
      originReferenceNum: originReferenceNum,
    );
  }

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
  }) async {
    if (!isActive) {
      return RequestResult.exception();
    }
    final uri = buildCreateTransactionUri(
      amountCents: amountCents,
      redirectUrl: _redirectUrl,
      transactionMethode: transactionMethode,
      originReferenceNum: originReferenceNum,
      clientID: clientID,
      printByPaymentApp: printByPaymentApp,
      preferableReceiptType: preferableReceiptType,
      clientPhone: clientPhone,
      clientEmail: clientEmail,
      tipAmountCents: tipAmountCents,
      tipCollect: tipCollect,
    );

    final redirectedUri = await _oeffnenUndWarten(
      uri,
      originReferenceNum: originReferenceNum,
      timeout: redirectTimeout ?? defaultTransactionRedirectTimeout,
    );
    if (redirectedUri is RequestResult) return redirectedUri;

    return requestResultFromCreateRedirect(
      redirectedUri as Uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
    );
  }

  static Future<RequestResult> cancelTransactionIOS({
    required String amsID,
    String? originReferenceNum,
    String? clientID,
    bool printByPaymentApp = true,
    PreferableReceiptType? preferableReceiptType,
    String? clientPhone,
    String? clientEmail,
    Duration? redirectTimeout,
  }) async {
    if (!isActive) {
      return RequestResult.exception();
    }

    final uri = buildCancelTransactionUri(
      amsID: amsID,
      redirectUrl: _redirectUrl,
      clientID: clientID,
      printByPaymentApp: printByPaymentApp,
      preferableReceiptType: preferableReceiptType,
      clientPhone: clientPhone,
      clientEmail: clientEmail,
    );

    final redirectedUri = await _oeffnenUndWarten(
      uri,
      originReferenceNum: originReferenceNum,
      timeout: redirectTimeout ?? defaultTransactionRedirectTimeout,
    );
    if (redirectedUri is RequestResult) return redirectedUri;

    return requestResultFromCancelRedirect(
      redirectedUri as Uri,
      printByPaymentApp: printByPaymentApp,
      originReferenceNum: originReferenceNum,
    );
  }

  /// Öffnet GP tom und wartet auf den zugehörigen Redirect.
  /// Liefert entweder den `Uri` des Redirects oder – wenn es dazu nicht kam –
  /// ein fertiges Fehler-[RequestResult].
  static Future<Object> _oeffnenUndWarten(
    Uri uri, {
    required String? originReferenceNum,
    required Duration timeout,
  }) async {
    // Vor dem Öffnen anmelden, damit kein Redirect verpasst wird.
    final waiter = _RedirectWaiter(originReferenceNum);
    _waiters.add(waiter);

    bool success;
    try {
      success = await _launch(uri);
    } catch (e) {
      _waiters.remove(waiter);
      return _pluginFehler(
        GptomResultCode.cannotOpen,
        GptomErrorCode.cannotOpen,
        'Konnte GP tom nicht öffnen',
      );
    }

    if (!success) {
      _waiters.remove(waiter);
      return _pluginFehler(
        GptomResultCode.cannotOpen,
        GptomErrorCode.cannotOpen,
        'Konnte GP tom nicht öffnen',
      );
    }

    try {
      return await waiter.completer.future.timeout(timeout);
    } on TimeoutException {
      // Der Wächter gibt auf; ein später eintreffender Redirect landet damit
      // im Puffer und ist über pendingRedirect() abholbar.
      _waiters.remove(waiter);
      return _pluginFehler(
        GptomResultCode.timeout,
        GptomErrorCode.timeout,
        'Kein Redirect erhalten oder Timeout',
      );
    }
  }
}
