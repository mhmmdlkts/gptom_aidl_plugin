import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/cancel_mode.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';
import 'package:gptom_aidl_plugin/models/batch.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';

/// Jeder kann `<scheme>://redirect?status=COMPLETED` öffnen. Im Token-Modus
/// (Standard) nimmt ein wartender Aufruf deshalb nur einen Redirect an, der
/// das geheime Token aus seiner eigenen `redirectUrl` trägt; alles andere
/// landet unbestätigt im Puffer und ergibt nie "bezahlt".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final hex32 = RegExp(r'^[0-9a-f]{32}$');

  /// Die zuletzt an GP tom geschickte Anfrage.
  Uri? gerufen;

  setUp(() {
    GptomSecurityConfig.current = const GptomSecurityConfig();
    GptomAidlPluginIOS.debugReset();
    GptomAidlPluginIOS.debugSetRedirectScheme('meineapp');
    gerufen = null;
  });

  tearDown(() {
    GptomAidlPluginIOS.debugReset();
    GptomSecurityConfig.current = const GptomSecurityConfig();
  });

  /// So antwortet GP tom: an die mitgegebene `redirectUrl`, mit eigenem Query.
  Uri antwortAuf(Uri anfrage, Map<String, String> query) =>
      Uri.parse(anfrage.queryParameters['redirectUrl']!)
          .replace(queryParameters: query);

  /// Das Token (Pfadsegment) aus der `redirectUrl` einer Anfrage.
  String tokenAus(Uri anfrage) =>
      Uri.parse(anfrage.queryParameters['redirectUrl']!).pathSegments.single;

  /// Ersetzt `launchUrl`: merkt sich die Anfrage und schickt – falls
  /// [antwort] gesetzt ist – danach den Redirect zurück.
  void gpTom({Uri Function(Uri anfrage)? antwort, bool oeffnenGelingt = true}) {
    GptomAidlPluginIOS.debugLauncher = (uri) async {
      gerufen = uri;
      if (antwort != null) {
        final redirect = antwort(uri);
        scheduleMicrotask(() => GptomAidlPluginIOS.debugHandleRedirect(redirect));
      }
      return oeffnenGelingt;
    };
  }

  Future<RequestResult> verkauf({
    String? requestId,
    String? referenz,
    Duration timeout = const Duration(milliseconds: 200),
  }) {
    return GptomAidlPlugin().sell(
      amountCents: 435,
      transactionMethode: TransactionMethode.card,
      referenz: referenz,
      requestId: requestId,
      timeout: timeout,
    );
  }

  group('Vorgangskennung', () {
    test('Verkauf schickt redirectUrl mit Token und gleiche requestID', () async {
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'COMPLETED', 'amsID': 'ams-1'}));

      final result = await verkauf();

      final redirectUrl = gerufen!.queryParameters['redirectUrl']!;
      final token = tokenAus(gerufen!);
      expect(token, matches(hex32));
      expect(redirectUrl, 'meineapp://redirect/$token');
      expect(gerufen!.queryParameters['requestID'], token);
      // GP tom erkennt den Anfrage-Typ per `contains` – im Pfad darf kein
      // Operationsname stehen.
      expect(redirectUrl, isNot(contains('login')));
      expect(redirectUrl, isNot(contains('status')));
      expect(result.result, GptomResultCode.success);
      expect(result.requestId, token);
    });

    test('vorgegebene requestId wird Token und steht im Ergebnis', () async {
      final id = GptomAidlPlugin.neueVorgangsId();
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'COMPLETED'}));

      final result = await verkauf(requestId: id);

      expect(tokenAus(gerufen!), id);
      expect(gerufen!.queryParameters['requestID'], id);
      expect(result.result, GptomResultCode.success);
      expect(result.requestId, id);
    });

    test("ungültige requestId 'RE-1' → ArgumentError", () async {
      gpTom();
      await expectLater(verkauf(requestId: 'RE-1'), throwsArgumentError);
      // GP tom wird gar nicht erst geöffnet.
      expect(gerufen, isNull);
    });

    test('neueVorgangsId: 32 Hex klein, jedes Mal anders', () {
      final a = GptomAidlPlugin.neueVorgangsId();
      expect(a, matches(hex32));
      expect(GptomAidlPluginIOS.neueVorgangsId(), isNot(a));
    });

    test('auch -1002 trägt die requestId', () async {
      final id = GptomAidlPlugin.neueVorgangsId();
      gpTom(oeffnenGelingt: false);

      final result = await verkauf(requestId: id);

      expect(result.result, GptomResultCode.cannotOpen);
      expect(result.requestId, id);
    });

    test('Storno: Token, requestID und requestId im Ergebnis', () async {
      final id = GptomAidlPlugin.neueVorgangsId();
      gpTom(antwort: (a) => antwortAuf(a, {
            'status': 'COMPLETED',
            'receipt': jsonEncode({'result': 0, 'amsID': 'ams-1', 'transactionID': 'gp-1'}),
          }));

      final result = await GptomAidlPlugin().voidSell(
        originTransactionId: 'ams-1',
        cancelMode: CancelMode.last,
        requestId: id,
        timeout: const Duration(milliseconds: 200),
      );

      expect(gerufen!.host, 'transaction');
      expect(gerufen!.path, '/cancel');
      expect(tokenAus(gerufen!), id);
      expect(gerufen!.queryParameters['requestID'], id);
      expect(result.result, GptomResultCode.success);
      expect(result.transactionId, 'gp-1');
      expect(result.requestId, id);
    });
  });

  group('Annahme nur mit Token', () {
    test('gefälschter Redirect ohne Token wird nicht angenommen', () async {
      gpTom(antwort: (_) => Uri.parse(
          'meineapp://redirect?status=COMPLETED&referenceNumber=RE-2026-001'));

      final result = await verkauf(
        referenz: 'RE-2026-001',
        timeout: const Duration(milliseconds: 50),
      );

      expect(result.result, GptomResultCode.timeout);
      expect(result.requestId, matches(hex32));
      expect(result.requestId, tokenAus(gerufen!));

      final gepuffert = GptomAidlPluginIOS.pendingRedirects.single;
      expect(gepuffert.originReferenceNum, 'RE-2026-001');
      expect(gepuffert.isVerified, isFalse);
      expect(gepuffert.requestId, isNull);
      final alsVerkauf = gepuffert.asSellResult();
      expect(alsVerkauf.result, GptomResultCode.unverified);
      expect(alsVerkauf.error?.errorCode, GptomErrorCode.unverified);
      expect(alsVerkauf.requestId, isNull);
      expect(GptomResultCode.istUnklar(alsVerkauf.result), isTrue);
      expect(gepuffert.asVoidResult().result, GptomResultCode.unverified);
    });

    test('falsches Token wird nicht angenommen', () async {
      final fremd = GptomAidlPlugin.neueVorgangsId();
      gpTom(antwort: (_) =>
          Uri.parse('meineapp://redirect/$fremd?status=COMPLETED&amsID=ams-1'));

      final result = await verkauf(timeout: const Duration(milliseconds: 50));

      expect(result.result, GptomResultCode.timeout);
      expect(result.requestId, isNot(fremd));
      final gepuffert = GptomAidlPluginIOS.pendingRedirects.single;
      expect(gepuffert.isVerified, isFalse);
      // Das fremde Token wird nicht herausgegeben.
      expect(gepuffert.requestId, isNull);
      expect(gepuffert.asSellResult().result, GptomResultCode.unverified);
      expect(gepuffert.asSellResult().requestId, isNull);
    });

    test('richtiges Token wird angenommen', () async {
      gpTom(antwort: (a) => antwortAuf(a, {
            'status': 'COMPLETED',
            'receipt': jsonEncode({'result': 0, 'amsID': 'ams-7', 'amount': '4.35'}),
          }));

      final result = await verkauf(referenz: 'RE-2026-001');

      expect(result.result, GptomResultCode.success);
      expect(result.transactionId, 'ams-7');
      expect(result.amountCents, 435);
      expect(result.requestId, tokenAus(gerufen!));
      expect(GptomAidlPluginIOS.pendingRedirects, isEmpty);
    });

    test('Scheme mit Großbuchstaben', () async {
      GptomAidlPluginIOS.debugSetRedirectScheme('MeineApp');
      gpTom(antwort: (a) {
        final antwort = antwortAuf(a, {'status': 'COMPLETED'});
        // Zurück kommt das Scheme klein geschrieben.
        expect(antwort.scheme, 'meineapp');
        return antwort;
      });

      final result = await verkauf();

      expect(gerufen!.queryParameters['redirectUrl'], startsWith('MeineApp://redirect/'));
      expect(result.result, GptomResultCode.success);
    });

    test('zwei gleichzeitige Roundtrips', () async {
      final anfragen = <Uri>[];
      GptomAidlPluginIOS.debugLauncher = (uri) async {
        anfragen.add(uri);
        return true;
      };
      Uri bauen(String redirectUrl) => Uri(
            scheme: 'gptom',
            host: 'transaction',
            path: 'detail',
            queryParameters: {'redirectUrl': redirectUrl},
          );

      final erster = GptomAidlPluginIOS.roundtrip(bauen, timeout: const Duration(seconds: 2));
      final zweiter = GptomAidlPluginIOS.roundtrip(bauen, timeout: const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(anfragen, hasLength(2));

      // Antworten in umgekehrter Reihenfolge.
      GptomAidlPluginIOS.debugHandleRedirect(antwortAuf(anfragen[1], {'antwort': 'zwei'}));
      GptomAidlPluginIOS.debugHandleRedirect(antwortAuf(anfragen[0], {'antwort': 'eins'}));

      final r1 = await erster;
      final r2 = await zweiter;
      expect(r1.cannotOpen, isFalse);
      expect(r1.redirect!.queryParameters['antwort'], 'eins');
      expect(r2.redirect!.queryParameters['antwort'], 'zwei');
      expect(GptomAidlPluginIOS.pendingRedirects, isEmpty);
    });
  });

  group('Puffer mit Bestätigung', () {
    test('Redirect mit Token nach Timeout landet bestätigt im Puffer', () async {
      gpTom();
      final result = await verkauf(timeout: const Duration(milliseconds: 30));
      expect(result.result, GptomResultCode.timeout);

      GptomAidlPluginIOS.debugHandleRedirect(
          antwortAuf(gerufen!, {'status': 'COMPLETED', 'amsID': 'ams-8'}));

      final gepuffert = GptomAidlPluginIOS.pendingRedirects.single;
      expect(gepuffert.isVerified, isTrue);
      expect(gepuffert.requestId, result.requestId);
      final alsVerkauf = gepuffert.asSellResult();
      expect(alsVerkauf.result, GptomResultCode.success);
      expect(alsVerkauf.transactionId, 'ams-8');
      expect(alsVerkauf.requestId, result.requestId);
    });

    test('Kaltstart: Bestätigung über requestId', () async {
      // Die Kasse speichert die Kennung vor dem Aufruf …
      final id = GptomAidlPlugin.neueVorgangsId();
      gpTom();
      await verkauf(requestId: id, timeout: const Duration(milliseconds: 10));
      // … dann beendet iOS die App: das Plugin kennt keine Tokens mehr.
      GptomAidlPluginIOS.debugReset();

      GptomAidlPluginIOS.debugHandleRedirect(
          Uri.parse('meineapp://redirect/$id?status=COMPLETED&amsID=ams-9'));
      expect(GptomAidlPluginIOS.pendingRedirects.single.isVerified, isFalse);
      expect(GptomAidlPluginIOS.pendingRedirects.single.requestId, isNull);

      // `id` kommt aus dem Speicher der Kasse, nicht aus dem Redirect.
      final offen = GptomAidlPlugin().pendingRedirect(requestId: id)!;
      expect(offen.isVerified, isTrue);
      expect(offen.requestId, id);
      final alsVerkauf = offen.asSellResult();
      expect(alsVerkauf.result, GptomResultCode.success);
      expect(alsVerkauf.transactionId, 'ams-9');
      expect(alsVerkauf.requestId, id);
      expect(GptomAidlPluginIOS.pendingRedirects, isEmpty);
    });

    test('unbekannte requestId: null, Puffer bleibt', () {
      GptomAidlPluginIOS.debugHandleRedirect(Uri.parse(
          'meineapp://redirect/${GptomAidlPlugin.neueVorgangsId()}?status=COMPLETED'));

      expect(
        GptomAidlPluginIOS.pendingRedirect(requestId: GptomAidlPlugin.neueVorgangsId()),
        isNull,
      );
      expect(GptomAidlPluginIOS.pendingRedirects, hasLength(1));
    });

    test('Fälschung zweimal: keine Vorgangskennung, also keine Bestätigung', () {
      // Angriff: derselbe gefälschte Link mit selbst gewähltem Token, zweimal.
      final y = GptomAidlPlugin.neueVorgangsId();
      final gefaelscht =
          Uri.parse('meineapp://redirect/$y?status=COMPLETED&amsID=ams-1');
      GptomAidlPluginIOS.debugHandleRedirect(gefaelscht);
      GptomAidlPluginIOS.debugHandleRedirect(gefaelscht);
      for (final offen in GptomAidlPluginIOS.pendingRedirects) {
        expect(offen.isVerified, isFalse);
        expect(offen.requestId, isNull);
      }

      final plugin = GptomAidlPlugin();
      final erster = plugin.pendingRedirect()!;
      final ergebnis = erster.asSellResult();
      expect(ergebnis.result, GptomResultCode.unverified);
      expect(ergebnis.requestId, isNull);
      expect(erster.asVoidResult().requestId, isNull);

      // Die Kasse will "über die requestId klären" – aus dem Ergebnis hat sie
      // keine, die zweite Kopie bleibt unbestätigt.
      final zweiter = plugin.pendingRedirect(requestId: ergebnis.requestId)!;
      expect(zweiter.isVerified, isFalse);
      expect(zweiter.asSellResult().result, GptomResultCode.unverified);
    });

    test('requestId bestätigt jedes passende Token – sicher nur mit der Kennung '
        'aus dem Speicher der Kasse', () {
      // Bewusst so: `pendingRedirect(requestId: y)` prüft nur, ob das Token
      // passt. Sicher ist das, weil y aus dem Speicher der Kasse stammen muss
      // (vor dem Aufruf gesichert) – das Plugin gibt das Token eines
      // unbestätigten Redirects nie heraus, die Kasse kann es also nicht
      // versehentlich aus einer Fälschung übernehmen.
      final y = GptomAidlPlugin.neueVorgangsId();
      GptomAidlPluginIOS.debugHandleRedirect(
          Uri.parse('meineapp://redirect/$y?status=COMPLETED&amsID=ams-1'));
      expect(GptomAidlPluginIOS.pendingRedirects.single.requestId, isNull);

      final offen = GptomAidlPluginIOS.pendingRedirect(requestId: y)!;
      expect(offen.isVerified, isTrue);
      expect(offen.requestId, y);
      expect(offen.asSellResult().result, GptomResultCode.success);
      expect(offen.asSellResult().requestId, y);
    });

    test('höchstens 50 Tokens bleiben gemerkt', () async {
      gpTom(oeffnenGelingt: false);
      Uri bauen(String redirectUrl) => Uri(
            scheme: 'gptom',
            host: 'status',
            queryParameters: {'redirectUrl': redirectUrl},
          );

      await GptomAidlPluginIOS.roundtrip(bauen, timeout: const Duration(seconds: 1));
      final aeltestes = gerufen!;
      for (var i = 0; i < 50; i++) {
        await GptomAidlPluginIOS.roundtrip(bauen, timeout: const Duration(seconds: 1));
      }
      final juengstes = gerufen!;

      GptomAidlPluginIOS.debugHandleRedirect(antwortAuf(aeltestes, {'status': 'COMPLETED'}));
      GptomAidlPluginIOS.debugHandleRedirect(antwortAuf(juengstes, {'status': 'COMPLETED'}));

      final puffer = GptomAidlPluginIOS.pendingRedirects;
      expect(puffer.first.isVerified, isFalse);
      expect(puffer.last.isVerified, isTrue);
    });
  });

  group('Schalter', () {
    test('sendRequestIdIOS aus: kein requestID, Token bleibt', () async {
      GptomSecurityConfig.current = const GptomSecurityConfig(sendRequestIdIOS: false);
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'COMPLETED'}));

      final result = await verkauf();

      expect(gerufen!.queryParameters.containsKey('requestID'), isFalse);
      final token = tokenAus(gerufen!);
      expect(token, matches(hex32));
      expect(result.result, GptomResultCode.success);
      expect(result.requestId, token);
    });

    test('redirectTokenIOS aus: redirectUrl ohne Pfad', () async {
      GptomSecurityConfig.current = const GptomSecurityConfig(redirectTokenIOS: false);
      gpTom(antwort: (_) => Uri.parse(
          'meineapp://redirect?status=COMPLETED&referenceNumber=RE-2026-001'));

      final result = await verkauf(referenz: 'RE-2026-001');

      expect(gerufen!.queryParameters['redirectUrl'], 'meineapp://redirect');
      // Altes Verhalten: Annahme nach Referenz.
      expect(result.result, GptomResultCode.success);
      // requestID hängt am eigenen Schalter und geht weiter mit.
      expect(result.requestId, matches(hex32));
      expect(gerufen!.queryParameters['requestID'], result.requestId);
    });
  });

  group('Kassenschnitt', () {
    final batch = {
      'saleCount': 1,
      'totalCount': 1,
      'saleAmount': 4.35,
      'totalAmount': 4.35,
      'currency': 'EUR',
      'amsId': 'ams-batch-1',
    };

    test('Kassenschnitt nutzt ein Token', () async {
      gpTom(antwort: (a) => antwortAuf(a, {'batch': jsonEncode(batch)}));

      final ergebnis = await GptomAidlPlugin().closeBatch(
        timeout: const Duration(milliseconds: 200),
      );

      expect(tokenAus(gerufen!), matches(hex32));
      // Der Kassenschnitt schickt keine requestID.
      expect(gerufen!.queryParameters.containsKey('requestID'), isFalse);
      expect(ergebnis, isA<Batch>());
      expect((ergebnis as Batch).totalAmountCents, 435);
    });

    test('Kassenschnitt nimmt keinen Redirect ohne Token an', () async {
      gpTom(antwort: (_) => Uri(
            scheme: 'meineapp',
            host: 'redirect',
            queryParameters: {'batch': jsonEncode(batch)},
          ));

      await expectLater(
        GptomAidlPluginIOS.closeBatchIOS(
          redirectTimeout: const Duration(milliseconds: 30),
        ),
        throwsException,
      );
      expect(GptomAidlPluginIOS.pendingRedirects.single.isVerified, isFalse);
    });
  });

  group('Rückerstattung und Belegabfrage', () {
    test('Rückerstattung liest den Beleg als refund und trägt die requestId', () async {
      gpTom(antwort: (a) => antwortAuf(a, {
            'status': 'COMPLETED',
            'receipt': jsonEncode({'result': 0, 'amount': '10,00', 'amsID': 'ams-9'}),
          }));

      final result = await GptomAidlPlugin().refund(
        amountCents: 1000,
        referenz: 'RE-1',
        timeout: const Duration(milliseconds: 200),
      );

      expect(gerufen!.path, '/refund');
      expect(result.result, 0);
      expect(result.amountCents, 1000);
      expect(result.transactionType, TransactionType.refund);
      expect(result.requestId, matches(hex32));
      expect(gerufen!.queryParameters['requestID'], result.requestId);
      expect(tokenAus(gerufen!), result.requestId);
    });

    test('Rückerstattung ohne Redirect liefert Timeout mit requestId', () async {
      gpTom();
      final id = GptomAidlPlugin.neueVorgangsId();
      final result = await GptomAidlPlugin().refund(
        amountCents: 1000,
        requestId: id,
        timeout: const Duration(milliseconds: 30),
      );
      expect(result.result, -1003);
      expect(result.requestId, id);
    });

    test('Rückerstattung mit ungültiger requestId wirft ArgumentError', () {
      gpTom();
      expect(
        () => GptomAidlPlugin().refund(amountCents: 1000, requestId: 'ABC'),
        throwsArgumentError,
      );
    });

    test('unbestätigter Redirect ergibt als Rückerstattung -1007 ohne requestId', () {
      final redirect = GptomPendingRedirect(
        Uri.parse('meineapp://redirect/${'a' * 32}?status=COMPLETED'),
        DateTime.now(),
        isVerified: false,
      );
      final r = redirect.asRefundResult();
      expect(r.result, -1007);
      expect(r.requestId, isNull);
    });

    test('Belegabfrage liest den Beleg mit eigenem Token', () async {
      gpTom(antwort: (a) => antwortAuf(a, {
            'status': 'COMPLETED',
            'receipt': jsonEncode({'result': 0, 'amount': '4,35', 'amsID': 'ams-2'}),
          }));
      final gesucht = GptomAidlPlugin.neueVorgangsId();

      final result = await GptomAidlPlugin().transactionDetailIOS(
        requestId: gesucht,
        timeout: const Duration(milliseconds: 200),
      );

      expect(gerufen!.path, '/detail');
      expect(gerufen!.queryParameters['requestID'], gesucht);
      expect(tokenAus(gerufen!), matches(hex32));
      expect(tokenAus(gerufen!), isNot(gesucht));
      expect(result.result, 0);
      expect(result.amountCents, 435);
      expect(result.requestId, gesucht);
    });

    test('Belegabfrage ohne amsId und requestId wirft ArgumentError', () {
      gpTom();
      expect(() => GptomAidlPlugin().transactionDetailIOS(), throwsArgumentError);
    });
  });
}
