import 'package:gptom_aidl_plugin/models/gptom_app_check.dart';
import 'package:gptom_aidl_plugin/models/gptom_info.dart';
import 'package:gptom_aidl_plugin/models/inquire_result.dart';
import 'package:gptom_aidl_plugin/models/login_status.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'gptom_aidl_plugin_method_channel.dart';
import 'models/register_result.dart';
import 'models/state_result.dart';

abstract class GptomAidlPluginPlatform extends PlatformInterface {
  /// Constructs a GptomAidlPluginPlatform.
  GptomAidlPluginPlatform() : super(token: _token);

  static final Object _token = Object();

  static GptomAidlPluginPlatform _instance = MethodChannelGptomAidlPlugin();

  /// The default instance of [GptomAidlPluginPlatform] to use.
  ///
  /// Defaults to [MethodChannelGptomAidlPlugin].
  static GptomAidlPluginPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [GptomAidlPluginPlatform] when
  /// they register themselves.
  static set instance(GptomAidlPluginPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<bool> existGpTomApp({bool isDevAndroid = false});

  /// Prüft die GP tom App (installiert, Signatur vertrauenswürdig).
  ///
  /// Achtung: Ohne konfigurierte Pins merkt sich der erste Aufruf den
  /// Fingerprint (trust on first use) – es ist keine reine Leseabfrage.
  Future<GptomAppCheck> checkGpTomApp({bool isDevAndroid = false});

  /// Verwirft den gemerkten Fingerprint (trust on first use), z. B. nach
  /// einem legitimen Signaturwechsel der GP tom App. Nur Android.
  Future<bool> resetTrustedSignature({bool isDevAndroid = false});
  Future<bool> bindService({bool isDevAndroid = false});
  Future<void> unbindService();
  Future<RegisterResult> registerTransactionV2Android(Map<String, dynamic> params);
  Future<RequestResult> requestTransactionV2Android(Map<String, dynamic> params);
  Future<StateResult> stateRequestAndroid(String transactionId);
  Future<InquireResult> inquireTransactionAndroid(String transactionId);
  Future<bool> createTransactionIOS();
  Future<bool> cancelTransactionIOS();

  /// Ergebnisse, die GP tom erst nach dem Wächter-Timeout geliefert hat
  /// (Android). Der MethodChannel-Aufruf hat da bereits mit TIMEOUT
  /// geantwortet; hierüber kann die App den Ausgang nachträglich auflösen.
  Stream<RequestResult> get lateTransactionResultStream;

  // --- Login-Service (AIDL 1.29.0, nur Android) ---
  Future<bool> bindLoginService({bool isDevAndroid = false});
  Future<void> unbindLoginService();
  Future<bool> loginGpTom({
    required String username,
    required String password,
    required String terminalId,
    String? authCode,
  });
  Future<bool> logoutGpTom();
  Future<bool> changeGpTomPassword({
    required String currentPassword,
    required String newPassword,
    String? authCode,
    bool validationOnly = false,
  });

  /// Status-Updates aus der GP tom App (Ergebnis von login/logout/changePassword).
  Stream<GpTomLoginEvent> get loginStatusStream;

  // --- Info-Service (nur Android) ---
  Future<bool> bindInfoService({bool isDevAndroid = false});
  Future<void> unbindInfoService();
  /// Fragt die App-Infos ab. Mit [timeout] bricht der native Wächter ab und
  /// wirft eine `PlatformException` mit Code `TIMEOUT`.
  Future<GpTomInfo?> getGpTomInfo({Duration? timeout});

  /// Push-Updates der GP tom App-Infos.
  Stream<GpTomInfo> get gpTomInfoStream;
}
