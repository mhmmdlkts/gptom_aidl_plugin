import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';
import 'package:gptom_aidl_plugin/gptom_security.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';

/// Der iOS-Weg kennt nur einen einzigen Rückkanal: den Redirect. Alles, was
/// dabei schiefgehen kann, muss für die Kasse unterscheidbar bleiben – sonst
/// wird eine belastete Karte als "abgebrochen" verbucht.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Diese Tests prüfen die Referenz-Zuordnung ohne Redirect-Token
    // (Altmodus); der Token-Modus hat eigene Tests in ios_token_test.dart.
    GptomSecurityConfig.current =
        const GptomSecurityConfig(redirectTokenIOS: false, sendRequestIdIOS: false);
    GptomAidlPluginIOS.debugReset();
    GptomAidlPluginIOS.debugSetRedirectScheme('meineapp');
  });

  tearDown(() {
    GptomAidlPluginIOS.debugReset();
    GptomSecurityConfig.current = const GptomSecurityConfig();
  });

  /// Öffnet GP tom (simuliert) und schickt danach [redirect] zurück.
  Future<T> mitRedirect<T>(
    Future<T> Function() aufruf, {
    Uri? redirect,
    bool oeffnenGelingt = true,
    Object? oeffnenWirft,
  }) {
    GptomAidlPluginIOS.debugLauncher = (uri) async {
      if (oeffnenWirft != null) throw oeffnenWirft;
      if (redirect != null) {
        // GP tom antwortet, sobald die eigene App wieder im Vordergrund ist.
        scheduleMicrotask(() => GptomAidlPluginIOS.debugHandleRedirect(redirect));
      }
      return oeffnenGelingt;
    };
    return aufruf();
  }

  Uri redirectMit({
    String? status,
    Map<String, dynamic>? receipt,
    String? receiptRaw,
    String? referenceNumber,
    String? amsID,
  }) {
    return Uri(
      scheme: 'meineapp',
      host: 'redirect',
      queryParameters: {
        if (status != null) 'status': status,
        if (receipt != null) 'receipt': jsonEncode(receipt),
        if (receiptRaw != null) 'receipt': receiptRaw,
        if (referenceNumber != null) 'referenceNumber': referenceNumber,
        if (amsID != null) 'amsID': amsID,
      },
    );
  }

  Future<RequestResult> verkauf({
    Uri? redirect,
    bool oeffnenGelingt = true,
    Object? oeffnenWirft,
    String? referenz,
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    return mitRedirect(
      () => GptomAidlPluginIOS.createTransactionIOS(
        amountCents: 435,
        transactionMethode: TransactionMethode.card,
        originReferenceNum: referenz,
        redirectTimeout: timeout,
      ),
      redirect: redirect,
      oeffnenGelingt: oeffnenGelingt,
      oeffnenWirft: oeffnenWirft,
    );
  }

  group('Ausgänge sind unterscheidbar', () {
    test('Zeitablauf: -1003 mit Fehlerkennung TIMEOUT', () async {
      final result = await verkauf(timeout: const Duration(milliseconds: 30));
      expect(result.result, GptomResultCode.timeout);
      expect(result.error?.errorCode, GptomErrorCode.timeout);
    });

    test('GP tom lässt sich nicht öffnen: -1002, kein Warten', () async {
      final result = await verkauf(oeffnenGelingt: false, timeout: const Duration(minutes: 5));
      expect(result.result, GptomResultCode.cannotOpen);
      expect(result.error?.errorCode, GptomErrorCode.cannotOpen);
    });

    test('launchUrl wirft: -1002 statt Ausnahme nach oben', () async {
      final result = await verkauf(
        oeffnenWirft: Exception('kein Ziel'),
        timeout: const Duration(minutes: 5),
      );
      expect(result.result, GptomResultCode.cannotOpen);
    });

    test('kein Beleg und Status ERROR: -1004', () async {
      final result = await verkauf(redirect: redirectMit(status: 'ERROR'));
      expect(result.result, GptomResultCode.noReceipt);
      expect(result.error?.errorCode, GptomErrorCode.noReceipt);
      expect(result.responseMessage, 'ERROR');
    });

    test('Abbruch am Terminal: -1006 (Doku: TASK_STATUS CANCELED)', () async {
      final result = await verkauf(redirect: redirectMit(status: 'CANCELED'));
      expect(result.result, GptomResultCode.cancelled);
      expect(result.error?.errorCode, GptomErrorCode.cancelled);
    });

    test('Abbruch auch in der Schreibweise CANCELLED', () async {
      final result = await verkauf(redirect: redirectMit(status: 'CANCELLED'));
      expect(result.result, GptomResultCode.cancelled);
    });

    test('Ablehnung: Terminal-Code bleibt erhalten', () async {
      final result = await verkauf(
        redirect: redirectMit(status: 'COMPLETED', receipt: {
          'result': -4,
          'amsID': 'ams-1',
          'amount': '4.35',
        }),
      );
      // Nicht -1004/-1003: der echte GP-tom-Code muss durchkommen.
      expect(result.result, -4);
      expect(result.error?.errorCode, GptomErrorCode.declined);
      expect(result.amountCents, 435);
    });

    test('Erfolg ohne amsID bleibt Erfolg, Referenz als Kennung', () async {
      final result = await verkauf(
        referenz: 'RE-2026-001',
        redirect: redirectMit(status: 'COMPLETED'),
      );
      expect(result.result, GptomResultCode.success);
      expect(result.transactionId, 'RE-2026-001');
    });
  });

  group('Belegdaten robust parsen', () {
    test('kaputtes JSON ist kein Zeitablauf, sondern -1005', () async {
      final result = await verkauf(
        redirect: redirectMit(status: 'COMPLETED', receiptRaw: '{kein json'),
      );
      expect(result.result, GptomResultCode.parseError);
      expect(result.error?.errorCode, GptomErrorCode.parseError);
    });

    test('Beleg, der kein Objekt ist, wirft nicht', () async {
      final result = await verkauf(
        redirect: redirectMit(status: 'COMPLETED', receiptRaw: '[1,2,3]'),
      );
      expect(result.result, GptomResultCode.parseError);
    });

    test('cardNumber als Zahl wird maskiert statt zu werfen', () {
      final result = GptomAidlPluginIOS.requestResultFromCreateRedirect(
        redirectMit(status: 'COMPLETED', receipt: {
          'result': 0,
          'amsID': 'ams-1',
          'cardNumber': 7866,
        }),
        printByPaymentApp: false,
      );
      expect(result.result, 0);
      expect(result.cardNumber, '**** **** **** 7866');
    });

    test('ungültiges Datum lässt die Felder leer, das Ergebnis bleibt Erfolg', () {
      final result = GptomAidlPluginIOS.requestResultFromCreateRedirect(
        redirectMit(status: 'COMPLETED', receipt: {
          'result': 0,
          'amsID': 'ams-1',
          'date': 'gestern',
        }),
        printByPaymentApp: false,
      );
      expect(result.result, 0);
      expect(result.date, isNull);
      expect(result.time, isNull);
    });

    test('result als String wird verstanden', () {
      final result = GptomAidlPluginIOS.requestResultFromCreateRedirect(
        redirectMit(status: 'COMPLETED', receipt: {
          'result': '0',
          'amsID': 'ams-1',
        }),
        printByPaymentApp: false,
      );
      expect(result.result, 0);
    });

    test('Beträge als Zahl statt String', () {
      final result = GptomAidlPluginIOS.requestResultFromCreateRedirect(
        redirectMit(status: 'COMPLETED', receipt: {
          'result': 0,
          'amount': 4.35,
          'totalAmount': 4.85,
        }),
        printByPaymentApp: false,
      );
      expect(result.amountCents, 435);
      expect(result.totalAmountCents, 485);
    });
  });

  group('Redirect-Zuordnung über die Referenz', () {
    test('fremder Redirect beantwortet die laufende Zahlung nicht', () async {
      GptomAidlPluginIOS.debugLauncher = (uri) async {
        scheduleMicrotask(() => GptomAidlPluginIOS.debugHandleRedirect(
              redirectMit(status: 'COMPLETED', referenceNumber: 'ALT-1', amsID: 'ams-alt'),
            ));
        return true;
      };

      final result = await GptomAidlPluginIOS.createTransactionIOS(
        amountCents: 100,
        transactionMethode: TransactionMethode.card,
        originReferenceNum: 'NEU-2',
        redirectTimeout: const Duration(milliseconds: 60),
      );

      expect(result.result, GptomResultCode.timeout);
      // Der fremde Redirect darf nicht verloren gehen.
      final gepuffert = GptomAidlPluginIOS.pendingRedirect();
      expect(gepuffert, isNotNull);
      expect(gepuffert!.originReferenceNum, 'ALT-1');
    });

    test('passende Referenz wird angenommen', () async {
      final result = await verkauf(
        referenz: 'NEU-2',
        redirect: redirectMit(
          status: 'COMPLETED',
          referenceNumber: 'NEU-2',
          receipt: {'result': 0, 'amsID': 'ams-2'},
        ),
      );
      expect(result.result, 0);
      expect(result.transactionId, 'ams-2');
      expect(GptomAidlPluginIOS.pendingRedirects, isEmpty);
    });

    test('Referenz im Beleg zählt genauso wie im Query', () {
      final uri = redirectMit(
        status: 'COMPLETED',
        receipt: {'result': 0, 'referenceNumber': 'RE-9'},
      );
      expect(GptomAidlPluginIOS.referenceFromRedirect(uri), 'RE-9');
    });

    test('Redirect ohne Referenz wird angenommen (dokumentierter Rückfall)', () async {
      final result = await verkauf(
        referenz: 'NEU-2',
        redirect: redirectMit(status: 'COMPLETED', amsID: 'ams-3'),
      );
      expect(result.result, 0);
      expect(result.transactionId, 'ams-3');
    });
  });

  group('sell auf dem iOS-Weg', () {
    late Uri gerufeneUri;

    Future<RequestResult> sell({String? referenz}) {
      GptomAidlPluginIOS.debugLauncher = (uri) async {
        gerufeneUri = uri;
        scheduleMicrotask(() => GptomAidlPluginIOS.debugHandleRedirect(
              redirectMit(status: 'COMPLETED', amsID: 'ams-1'),
            ));
        return true;
      };
      return GptomAidlPlugin().sell(
        amountCents: 435,
        transactionMethode: TransactionMethode.card,
        referenz: referenz,
        timeout: const Duration(milliseconds: 200),
      );
    }

    test('übernimmt die Referenz der App', () async {
      final result = await sell(referenz: 'RE-2026-001');
      expect(result.result, 0);
      expect(gerufeneUri.queryParameters['originReferenceNum'], 'RE-2026-001');
    });

    test('erzeugt eine Referenz, wenn die App keine mitgibt', () async {
      await sell();
      final referenz = gerufeneUri.queryParameters['originReferenceNum'];
      expect(referenz, isNotNull);
      expect(referenz, isNotEmpty);
      // GP tom nimmt höchstens 20 Zeichen (Doku "Transaction Sales (iOS)").
      expect(referenz!.length, lessThanOrEqualTo(20));
    });

    test('zwei erzeugte Referenzen sind verschieden', () {
      expect(GptomAidlPlugin.neueReferenz(), isNot(GptomAidlPlugin.neueReferenz()));
      expect(GptomAidlPlugin.neueReferenz().length, lessThanOrEqualTo(20));
    });
  });

  group('Puffer für Redirects ohne Wartenden (Kaltstart)', () {
    test('Redirect ohne wartenden Aufruf ist abholbar', () {
      GptomAidlPluginIOS.debugHandleRedirect(
        redirectMit(status: 'COMPLETED', referenceNumber: 'RE-1', amsID: 'ams-1'),
      );

      final offen = GptomAidlPluginIOS.pendingRedirect();
      expect(offen, isNotNull);
      expect(offen!.originReferenceNum, 'RE-1');
      expect(offen.status, 'COMPLETED');
      expect(offen.asSellResult().result, 0);
      expect(offen.asSellResult().transactionId, 'ams-1');
    });

    test('Abholen entfernt den Eintrag', () {
      GptomAidlPluginIOS.debugHandleRedirect(redirectMit(status: 'COMPLETED', amsID: 'a'));
      expect(GptomAidlPluginIOS.pendingRedirect(), isNotNull);
      expect(GptomAidlPluginIOS.pendingRedirect(), isNull);
    });

    test('gezieltes Abholen über die Referenz', () {
      GptomAidlPluginIOS.debugHandleRedirect(
          redirectMit(status: 'COMPLETED', referenceNumber: 'A'));
      GptomAidlPluginIOS.debugHandleRedirect(
          redirectMit(status: 'COMPLETED', referenceNumber: 'B'));

      final b = GptomAidlPluginIOS.pendingRedirect(originReferenceNum: 'B');
      expect(b?.originReferenceNum, 'B');
      // A bleibt liegen.
      expect(GptomAidlPluginIOS.pendingRedirects.single.originReferenceNum, 'A');
      // Nach nichts Passendem wird nichts geliefert und nichts entfernt.
      expect(GptomAidlPluginIOS.pendingRedirect(originReferenceNum: 'C'), isNull);
      expect(GptomAidlPluginIOS.pendingRedirects, hasLength(1));
    });

    test('Puffer wächst nicht unbegrenzt', () {
      final anzahl = GptomAidlPluginIOS.maxPendingRedirects + 5;
      for (var i = 0; i < anzahl; i++) {
        GptomAidlPluginIOS.debugHandleRedirect(
            redirectMit(status: 'COMPLETED', referenceNumber: 'R$i'));
      }
      expect(
        GptomAidlPluginIOS.pendingRedirects,
        hasLength(GptomAidlPluginIOS.maxPendingRedirects),
      );
      // Die jüngsten Redirects überleben, die ältesten fallen heraus.
      expect(GptomAidlPluginIOS.pendingRedirects.last.originReferenceNum, 'R${anzahl - 1}');
      expect(GptomAidlPluginIOS.pendingRedirects.first.originReferenceNum, 'R5');
    });

    test('die Fassade reicht den Puffer durch', () {
      GptomAidlPluginIOS.debugHandleRedirect(
          redirectMit(status: 'COMPLETED', referenceNumber: 'RE-7'));

      final plugin = GptomAidlPlugin();
      expect(plugin.pendingRedirects.single.originReferenceNum, 'RE-7');
      expect(plugin.pendingRedirect(originReferenceNum: 'RE-7'), isNotNull);
      expect(plugin.pendingRedirects, isEmpty);
    });

    test('listenIOS ist mehrfach aufrufbar und setzt die Redirect-URL', () {
      final plugin = GptomAidlPlugin();
      plugin.listenIOS('meineapp');
      plugin.listenIOS('meineapp');
      expect(GptomAidlPluginIOS.redirectUrl, 'meineapp://redirect');
    });

    test('gepufferter Storno-Redirect lässt sich als Storno lesen', () {
      GptomAidlPluginIOS.debugHandleRedirect(redirectMit(
        status: 'COMPLETED',
        receipt: {'result': 0, 'amsID': 'ams-1', 'transactionID': 'gp-1'},
      ));
      final offen = GptomAidlPluginIOS.pendingRedirect()!;
      expect(offen.asVoidResult().transactionId, 'gp-1');
      expect(offen.asSellResult().transactionId, 'ams-1');
    });
  });
}
