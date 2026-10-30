import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/enums/cancel_mode.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/enums/transaction_type.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';
import 'package:gptom_aidl_plugin/gptom_ios_account.dart';
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
      // Zahlungs-Tokens: nur deren späte Redirects kommen bestätigt in den
      // Puffer (Status & Co. gar nicht).
      Uri bauen(String redirectUrl) => Uri(
            scheme: 'gptom',
            host: 'transaction',
            path: 'create',
            queryParameters: {'redirectUrl': redirectUrl},
          );
      Future<void> zahlung() => GptomAidlPluginIOS.roundtrip(bauen,
          timeout: const Duration(seconds: 1), zahlung: true);

      await zahlung();
      final aeltestes = gerufen!;
      for (var i = 0; i < 50; i++) {
        await zahlung();
      }
      final juengstes = gerufen!;

      GptomAidlPluginIOS.debugHandleRedirect(antwortAuf(aeltestes, {'status': 'COMPLETED'}));
      GptomAidlPluginIOS.debugHandleRedirect(antwortAuf(juengstes, {'status': 'COMPLETED'}));

      final puffer = GptomAidlPluginIOS.pendingRedirects;
      expect(puffer.first.isVerified, isFalse);
      expect(puffer.last.isVerified, isTrue);
    });
  });

  group('Späte Redirects ohne Zahlungsbezug', () {
    // Status, Login, Kassenschnitt & Co. tragen ein eigenes Token. Kommt ihr
    // Redirect erst nach dem Timeout, darf er nie als Zahlung lesbar werden.
    test('Status: später Redirect landet nicht im Zahlungspuffer', () async {
      gpTom();
      final st = await GptomIosAccount.status(
          timeout: const Duration(milliseconds: 20));
      expect(st.fehler, GptomLoginOutcome.timeout);

      GptomAidlPluginIOS.debugHandleRedirect(antwortAuf(gerufen!, {
        'status': 'COMPLETED',
        'appStatus': '{"appVersion":"1"}',
      }));

      expect(GptomAidlPluginIOS.pendingRedirects, isEmpty);
      expect(GptomAidlPlugin().pendingRedirect(), isNull);
    });

    test('Login: später Redirect landet nicht im Zahlungspuffer', () async {
      gpTom();
      final r = await GptomIosAccount.login(
        const GptomCredentials(
          username: 'livia@melisse-nails.example',
          password: 'Geheim 1+2&3%#ä',
          terminalId: '12345678',
        ),
        timeout: const Duration(milliseconds: 20),
      );
      expect(r.outcome, GptomLoginOutcome.timeout);

      GptomAidlPluginIOS.debugHandleRedirect(
          antwortAuf(gerufen!, {'status': 'COMPLETED'}));

      expect(GptomAidlPluginIOS.pendingRedirects, isEmpty);
      expect(GptomAidlPlugin().pendingRedirect(), isNull);
    });

    test('Kassenschnitt: später Redirect landet nicht im Zahlungspuffer',
        () async {
      gpTom();
      await expectLater(
        GptomAidlPluginIOS.closeBatchIOS(
          redirectTimeout: const Duration(milliseconds: 20),
        ),
        throwsException,
      );

      GptomAidlPluginIOS.debugHandleRedirect(
          antwortAuf(gerufen!, {'status': 'COMPLETED'}));

      expect(GptomAidlPluginIOS.pendingRedirects, isEmpty);
      expect(GptomAidlPlugin().pendingRedirect(), isNull);
    });

    test('der Rohstrom führt den späten Redirect trotzdem', () async {
      gpTom();
      final roh = <Uri>[];
      final abo = GptomAidlPluginIOS.gptomRedirectStream.stream.listen(roh.add);
      addTearDown(abo.cancel);
      await GptomIosAccount.status(timeout: const Duration(milliseconds: 20));

      final spaet = antwortAuf(gerufen!, {'status': 'COMPLETED'});
      GptomAidlPluginIOS.debugHandleRedirect(spaet);
      await pumpEventQueue();

      expect(roh, [spaet]);
      expect(GptomAidlPluginIOS.pendingRedirects, isEmpty);
    });
  });

  group('Doppelte Redirects', () {
    test('Kopie eines schon beantworteten Verkaufs ist unbestätigt', () async {
      Uri? antwort;
      gpTom(antwort: (a) =>
          antwort = antwortAuf(a, {'status': 'COMPLETED', 'amsID': 'ams-1'}));
      final result = await verkauf();
      expect(result.result, GptomResultCode.success);

      // GP tom schickt denselben Redirect ein zweites Mal.
      GptomAidlPluginIOS.debugHandleRedirect(antwort!);

      final offen = GptomAidlPlugin().pendingRedirect()!;
      expect(offen.isVerified, isFalse);
      expect(offen.requestId, isNull);
      expect(offen.asSellResult().result, GptomResultCode.unverified);
    });

    test('Kopie nach Abholung über requestId ist unbestätigt', () async {
      final id = GptomAidlPlugin.neueVorgangsId();
      gpTom();
      await verkauf(requestId: id, timeout: const Duration(milliseconds: 20));
      final spaet =
          antwortAuf(gerufen!, {'status': 'COMPLETED', 'amsID': 'ams-2'});
      GptomAidlPluginIOS.debugHandleRedirect(spaet);

      final erster = GptomAidlPlugin().pendingRedirect(requestId: id)!;
      expect(erster.isVerified, isTrue);
      expect(erster.asSellResult().result, GptomResultCode.success);

      GptomAidlPluginIOS.debugHandleRedirect(spaet);
      final kopie = GptomAidlPlugin().pendingRedirect(requestId: id)!;
      expect(kopie.isVerified, isFalse);
      expect(kopie.asSellResult().result, GptomResultCode.unverified);
    });

    test('Kopie nach Abholung ohne Angabe ist unbestätigt', () async {
      gpTom();
      await verkauf(timeout: const Duration(milliseconds: 20));
      final spaet =
          antwortAuf(gerufen!, {'status': 'COMPLETED', 'amsID': 'ams-3'});
      GptomAidlPluginIOS.debugHandleRedirect(spaet);
      expect(GptomAidlPlugin().pendingRedirect()!.isVerified, isTrue);

      GptomAidlPluginIOS.debugHandleRedirect(spaet);
      final kopie = GptomAidlPlugin().pendingRedirect()!;
      expect(kopie.isVerified, isFalse);
      expect(kopie.asSellResult().result, GptomResultCode.unverified);
    });

    test('zwei Kopien im Puffer: nur die erste ist bestätigt', () async {
      gpTom();
      await verkauf(timeout: const Duration(milliseconds: 20));
      final spaet =
          antwortAuf(gerufen!, {'status': 'COMPLETED', 'amsID': 'ams-4'});
      GptomAidlPluginIOS.debugHandleRedirect(spaet);
      GptomAidlPluginIOS.debugHandleRedirect(spaet);

      final puffer = GptomAidlPluginIOS.pendingRedirects;
      expect(puffer.map((p) => p.isVerified), [true, false]);
    });
  });

  group('Abholung bevorzugt bestätigte Redirects', () {
    test('ohne Angabe: erst der bestätigte, dann der unbestätigte', () async {
      // Zuerst eine Fälschung, dann die echte (verspätete) Antwort.
      GptomAidlPluginIOS.debugHandleRedirect(
          Uri.parse('meineapp://redirect?status=COMPLETED&amsID=falsch'));
      gpTom();
      await verkauf(timeout: const Duration(milliseconds: 20));
      GptomAidlPluginIOS.debugHandleRedirect(
          antwortAuf(gerufen!, {'status': 'COMPLETED', 'amsID': 'ams-echt'}));

      final plugin = GptomAidlPlugin();
      final erster = plugin.pendingRedirect()!;
      expect(erster.isVerified, isTrue);
      expect(erster.asSellResult().transactionId, 'ams-echt');
      final zweiter = plugin.pendingRedirect()!;
      expect(zweiter.isVerified, isFalse);
      expect(plugin.pendingRedirect(), isNull);
    });

    test('mit Referenz: der bestätigte vor einer Fälschung mit gleicher Referenz',
        () async {
      GptomAidlPluginIOS.debugHandleRedirect(Uri.parse(
          'meineapp://redirect?status=COMPLETED&referenceNumber=RE-2026-001'));
      gpTom();
      await verkauf(
          referenz: 'RE-2026-001', timeout: const Duration(milliseconds: 20));
      GptomAidlPluginIOS.debugHandleRedirect(antwortAuf(gerufen!, {
        'status': 'COMPLETED',
        'referenceNumber': 'RE-2026-001',
        'amsID': 'ams-echt',
      }));

      final offen =
          GptomAidlPlugin().pendingRedirect(originReferenceNum: 'RE-2026-001')!;
      expect(offen.isVerified, isTrue);
      expect(offen.asSellResult().transactionId, 'ams-echt');
    });

    test('Puffer voll mit Fälschungen: der bestätigte bleibt', () async {
      gpTom();
      final result = await verkauf(timeout: const Duration(milliseconds: 20));
      GptomAidlPluginIOS.debugHandleRedirect(
          antwortAuf(gerufen!, {'status': 'COMPLETED', 'amsID': 'ams-echt'}));

      for (var i = 0; i < GptomAidlPluginIOS.maxPendingRedirects + 2; i++) {
        GptomAidlPluginIOS.debugHandleRedirect(Uri.parse(
            'meineapp://redirect/${GptomAidlPlugin.neueVorgangsId()}?status=COMPLETED'));
      }

      final puffer = GptomAidlPluginIOS.pendingRedirects;
      expect(puffer, hasLength(GptomAidlPluginIOS.maxPendingRedirects));
      expect(puffer.where((p) => p.isVerified), hasLength(1));
      final offen = GptomAidlPlugin().pendingRedirect()!;
      expect(offen.isVerified, isTrue);
      expect(offen.requestId, result.requestId);
      expect(offen.asSellResult().result, GptomResultCode.success);
    });

    test('Puffer voll: unbestätigte fallen vor bestätigten heraus', () async {
      final ids = <String>[];
      gpTom();
      for (var i = 0; i < 2; i++) {
        final r = await verkauf(timeout: const Duration(milliseconds: 10));
        ids.add(r.requestId!);
        GptomAidlPluginIOS.debugHandleRedirect(
            antwortAuf(gerufen!, {'status': 'COMPLETED', 'amsID': 'ams-$i'}));
      }
      for (var i = 0; i < GptomAidlPluginIOS.maxPendingRedirects; i++) {
        GptomAidlPluginIOS.debugHandleRedirect(
            Uri.parse('meineapp://redirect?status=COMPLETED&amsID=f$i'));
      }

      final puffer = GptomAidlPluginIOS.pendingRedirects;
      expect(puffer, hasLength(GptomAidlPluginIOS.maxPendingRedirects));
      expect(puffer.where((p) => p.isVerified).map((p) => p.requestId), ids);
      // Von den Fälschungen bleiben nur die jüngsten.
      expect(puffer.last.uri.queryParameters['amsID'],
          'f${GptomAidlPluginIOS.maxPendingRedirects - 1}');
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

    test('Belegabfrage: COMPLETED ohne Beleg ist kein Erfolg (-1004)', () async {
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'COMPLETED', 'amsID': 'ams-2'}));
      final gesucht = GptomAidlPlugin.neueVorgangsId();

      final result = await GptomAidlPlugin().transactionDetailIOS(
        requestId: gesucht,
        timeout: const Duration(milliseconds: 200),
      );

      expect(result.result, GptomResultCode.noReceipt);
      expect(result.error?.errorCode, GptomErrorCode.noReceipt);
      expect(result.responseMessage, 'COMPLETED');
      expect(result.transactionType, isNull);
      expect(result.requestId, gesucht);
    });

    test('Belegabfrage: ERROR mit error-Wert wird -1004 mit diesem Wert', () async {
      gpTom(antwort: (a) =>
          antwortAuf(a, {'status': 'ERROR', 'error': 'transactionNotFound'}));

      final result = await GptomAidlPlugin().transactionDetailIOS(
        amsId: 'ams-unbekannt',
        timeout: const Duration(milliseconds: 200),
      );

      expect(result.result, GptomResultCode.noReceipt);
      expect(result.error?.errorCode, 'transactionNotFound');
      expect(result.error?.result, GptomResultCode.noReceipt);
      expect(result.responseMessage, 'ERROR');
    });

    test('Belegabfrage mit Beleg: gelesen, aber ohne transactionType', () async {
      gpTom(antwort: (a) => antwortAuf(a, {
            'status': 'COMPLETED',
            'receipt': jsonEncode({
              'result': 0,
              'amount': '4,35',
              'amsID': 'ams-2',
              // Im Beleg ist transactionType die Zahlungsart, nicht Verkauf/Storno.
              'transactionType': 'CARD',
            }),
          }));

      final result = await GptomAidlPlugin().transactionDetailIOS(
        amsId: 'ams-2',
        timeout: const Duration(milliseconds: 200),
      );

      expect(result.result, GptomResultCode.success);
      expect(result.amountCents, 435);
      expect(result.transactionId, 'ams-2');
      expect(result.transactionType, isNull);
    });

    test('Belegabfrage nur per requestId bei sendRequestIdIOS aus: ArgumentError '
        'vor dem Öffnen', () async {
      GptomSecurityConfig.current =
          const GptomSecurityConfig(sendRequestIdIOS: false);
      gpTom(antwort: (a) => antwortAuf(a, {'status': 'COMPLETED'}));

      await expectLater(
        GptomAidlPlugin().transactionDetailIOS(
          requestId: GptomAidlPlugin.neueVorgangsId(),
          timeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          'transactionDetailIOS: Abfrage per requestId braucht sendRequestIdIOS – amsId angeben',
        )),
      );
      expect(gerufen, isNull);

      // Mit amsId geht es weiter – nur ohne requestID an GP tom.
      await GptomAidlPlugin().transactionDetailIOS(
        amsId: 'ams-2',
        requestId: GptomAidlPlugin.neueVorgangsId(),
        timeout: const Duration(milliseconds: 200),
      );
      expect(gerufen!.queryParameters['amsID'], 'ams-2');
      expect(gerufen!.queryParameters.containsKey('requestID'), isFalse);
    });

    test('Belegabfrage ohne amsId und requestId wirft ArgumentError', () {
      gpTom();
      expect(() => GptomAidlPlugin().transactionDetailIOS(), throwsArgumentError);
    });
  });
}
