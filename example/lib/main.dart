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

  // GP tom Anmeldung: alle Felder starten leer. Eingaben landen nie im Log.
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _newPassCtrl = TextEditingController();
  final _tidCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    _newPassCtrl.dispose();
    _tidCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

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
        return _plugin.bindService(
            isDevAndroid: _isDev, uriSchemeIOS: 'gptomexample');
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

  GptomCredentials get _credentials => GptomCredentials(
        username: _userCtrl.text,
        password: _passCtrl.text,
        terminalId: _tidCtrl.text,
      );

  String? get _code => _codeCtrl.text.isEmpty ? null : _codeCtrl.text;

  /// Im Log stehen nur Ausgang und rohe Status-/Fehlerwerte, nie Eingaben.
  String _describe(GptomLoginResult r) =>
      'outcome=${r.outcome.name} rawStatus=${r.rawStatus} rawError=${r.rawError}'
      '${r.needsCode ? ' (Code nötig)' : ''}';

  Future<void> _checkApp() => _run('App prüfen', () async {
        final check = await _plugin.checkGpTomApp(isDevAndroid: _isDev);
        return 'installed=${check.installed} trusted=${check.trusted} '
            'source=${check.source.name} version=${check.versionName} '
            'fingerprint=${check.signatureSha256.join(', ')}';
      });

  Future<void> _status() => _run('Status', () async {
        final info = await _plugin.getStatus(isDevAndroid: _isDev);
        if (info == null) return 'kein Ergebnis';
        return 'loginState=${info.loginState.name} tid=${info.tid}';
      });

  Future<void> _login({bool mitCode = false}) =>
      _run(mitCode ? 'Login mit Code' : 'Login', () async {
        final r = await _plugin.login(
          _credentials,
          authCode: mitCode ? _code : null,
          isDevAndroid: _isDev,
        );
        return _describe(r);
      });

  Future<void> _passwordStep({required bool mitCode}) =>
      _run(mitCode ? 'Passwort Schritt 2' : 'Passwort Schritt 1', () async {
        final r = await _plugin.changePassword(
          username: _userCtrl.text.trim(),
          currentPassword: _passCtrl.text,
          newPassword: _newPassCtrl.text,
          terminalId: _tidCtrl.text.trim(),
          code: mitCode ? _code : null,
          isDevAndroid: _isDev,
        );
        return _describe(r);
      });

  Future<void> _logout() => _run('Logout', () async {
        return _describe(await _plugin.logout(isDevAndroid: _isDev));
      });

  Future<void> _morningCheck() => _run('Morgen-Check', () async {
        final r = await _plugin.ensureLoggedIn(
          expectedTerminalId:
              _tidCtrl.text.trim().isEmpty ? null : _tidCtrl.text,
          credentials: () => _credentials,
          isDevAndroid: _isDev,
        );
        return _describe(r);
      });

  Widget _field(TextEditingController c, String label,
          {bool obscure = false}) =>
      SizedBox(
        width: 180,
        child: TextField(
          controller: c,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: !obscure,
          decoration: InputDecoration(labelText: label, isDense: true),
        ),
      );

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
                ElevatedButton(
                    onPressed: _sell, child: const Text('Sale 1,00')),
                ElevatedButton(onPressed: _state, child: const Text('Status')),
                ElevatedButton(
                    onPressed: _inquire, child: const Text('Details')),
                ElevatedButton(
                    onPressed: _voidSell, child: const Text('Storno')),
                ElevatedButton(
                    onPressed: _closeBatch, child: const Text('Kassenschnitt')),
              ],
            ),
            const Divider(),
            Flexible(
              child: SingleChildScrollView(
                child: ExpansionTile(
                  title: const Text('GP tom Anmeldung'),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _field(_userCtrl, 'Benutzer'),
                        _field(_passCtrl, 'Passwort', obscure: true),
                        _field(_newPassCtrl, 'Neues Passwort', obscure: true),
                        _field(_tidCtrl, 'TID'),
                        _field(_codeCtrl, 'Code'),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        ElevatedButton(
                            onPressed: _checkApp,
                            child: const Text('App prüfen')),
                        ElevatedButton(
                            onPressed: _status, child: const Text('Status')),
                        ElevatedButton(
                            onPressed: _login, child: const Text('Login')),
                        ElevatedButton(
                            onPressed: () => _login(mitCode: true),
                            child: const Text('Login mit Code')),
                        ElevatedButton(
                            onPressed: () => _passwordStep(mitCode: false),
                            child: const Text('Passwort Schritt 1')),
                        ElevatedButton(
                            onPressed: () => _passwordStep(mitCode: true),
                            child: const Text('Passwort Schritt 2')),
                        ElevatedButton(
                            onPressed: _logout, child: const Text('Logout')),
                        ElevatedButton(
                            onPressed: _morningCheck,
                            child: const Text('Morgen-Check')),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const Divider(),
            Expanded(
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) => Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
