import 'package:flutter/material.dart';
import 'package:gptom_aidl_plugin/enums/cancel_mode.dart';
import 'package:gptom_aidl_plugin/enums/preferable_receipt_type.dart';
import 'package:gptom_aidl_plugin/enums/transaction_methode.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';

void main() {
  runApp(const MyApp());
}

/// Manueller Test-Harness für das Plugin: kompletter Ablauf
/// bind -> register -> sell -> state -> inquire sowie Storno und
/// Kassenschnitt. Auf einem Gerät mit installierter GP tom App ausführen.
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _plugin = GptomAidlPlugin();
  final _log = <String>[];
  String? _lastTransactionId;
  String? _lastOriginTransactionId;
  bool _isDev = false;

  void _append(String line) {
    setState(() => _log.insert(0, line));
  }

  Future<void> _run(String label, Future<Object?> Function() action) async {
    try {
      final result = await action();
      _append('$label: $result');
    } catch (e) {
      _append('$label FEHLER: $e');
    }
  }

  Future<void> _bind() => _run('bindService', () async {
        // Auf iOS muss hier das eigene URL-Scheme der App stehen.
        return _plugin.bindService(isDevAndroid: _isDev, uriSchemeIOS: 'gptomexample');
      });

  Future<void> _sell() => _run('sell', () async {
        String? transactionId;
        if (!_isIOS) {
          final register = await _plugin.registerTransactionV2Android();
          if (!register.isSuccess) {
            return 'Registrierung fehlgeschlagen: $register';
          }
          transactionId = register.transactionId;
          _lastTransactionId = transactionId;
        }
        final RequestResult result = await _plugin.sell(
          transactionIdAndroid: transactionId,
          amountCents: 100, // 1,00 EUR
          transactionMethode: TransactionMethode.card,
          preferableReceiptType: PreferableReceiptType.print,
        );
        _lastOriginTransactionId = result.transactionId;
        return result;
      });

  Future<void> _state() => _run('stateRequest', () async {
        final id = _lastTransactionId;
        if (id == null) return 'keine Transaktion registriert';
        return _plugin.stateRequestAndroid(id);
      });

  Future<void> _inquire() => _run('inquireTransaction', () async {
        final id = _lastTransactionId;
        if (id == null) return 'keine Transaktion registriert';
        return _plugin.inquireTransactionAndroid(id);
      });

  Future<void> _voidSell() => _run('voidSell', () async {
        final origin = _lastOriginTransactionId;
        if (origin == null) return 'keine Transaktion zum Stornieren';
        String? transactionId;
        if (!_isIOS) {
          final register = await _plugin.registerTransactionV2Android();
          transactionId = register.transactionId;
        }
        return _plugin.voidSell(
          transactionIdAndroid: transactionId,
          originTransactionId: origin,
          cancelMode: CancelMode.last,
        );
      });

  Future<void> _closeBatch() => _run('closeBatch', () async {
        String? transactionId;
        if (!_isIOS) {
          final register = await _plugin.registerTransactionV2Android();
          transactionId = register.transactionId;
        }
        return _plugin.closeBatch(transactionIdAndroid: transactionId);
      });

  bool get _isIOS => Theme.of(context).platform == TargetPlatform.iOS;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('GPTom Plugin Example')),
        body: Column(
          children: [
            SwitchListTile(
              title: const Text('GP tom Dev-Package (nur Android)'),
              value: _isDev,
              onChanged: (v) => setState(() => _isDev = v),
            ),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(onPressed: _bind, child: const Text('Bind')),
                ElevatedButton(onPressed: _sell, child: const Text('Sale 1,00')),
                ElevatedButton(onPressed: _state, child: const Text('Status')),
                ElevatedButton(onPressed: _inquire, child: const Text('Details')),
                ElevatedButton(onPressed: _voidSell, child: const Text('Storno')),
                ElevatedButton(onPressed: _closeBatch, child: const Text('Kassenschnitt')),
              ],
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Text(_log[i], style: const TextStyle(fontSize: 12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
