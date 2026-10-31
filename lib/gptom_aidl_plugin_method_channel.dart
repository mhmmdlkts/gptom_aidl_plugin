import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gptom_aidl_plugin/gptom_security.dart';
import 'package:gptom_aidl_plugin/models/gptom_app_check.dart';
import 'package:gptom_aidl_plugin/models/gptom_info.dart';
import 'package:gptom_aidl_plugin/models/inquire_result.dart';
import 'package:gptom_aidl_plugin/models/login_status.dart';
import 'package:gptom_aidl_plugin/gptom_result_code.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';
import 'package:url_launcher/url_launcher.dart';

import 'gptom_aidl_plugin_ios.dart';
import 'gptom_aidl_plugin_platform_interface.dart';
import 'models/register_result.dart';
import 'models/state_result.dart';

class MethodChannelGptomAidlPlugin extends GptomAidlPluginPlatform {
  MethodChannelGptomAidlPlugin() {
    methodChannel.setMethodCallHandler(_handleNativeCall);
  }

  final methodChannel = const MethodChannel('gptom_aidl_plugin');

  final StreamController<GpTomLoginEvent> _loginStatusController =
      StreamController<GpTomLoginEvent>.broadcast();
  final StreamController<GpTomInfo> _gpTomInfoController =
      StreamController<GpTomInfo>.broadcast();
  final StreamController<RequestResult> _lateTransactionController =
      StreamController<RequestResult>.broadcast();

  /// Verarbeitet Pushes aus dem nativen Code (AIDL-Callbacks).
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onLateTransactionResult':
        final raw = call.arguments;
        if (raw is String) {
          _lateTransactionController.add(RequestResult.fromJson(raw));
        }
        break;
      case 'onLoginStatusChanged':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final rawStatus = args['status'] as String?;
        _loginStatusController.add(GpTomLoginEvent(
          status: GpTomLoginStatus.fromKey(rawStatus),
          rawStatus: rawStatus,
          message: args['message'] as String?,
        ));
        break;
      case 'onGpTomInfoChanged':
        final raw = call.arguments;
        if (raw is String) {
          _gpTomInfoController.add(GpTomInfo.fromJson(raw));
        }
        break;
    }
    return null;
  }

  /// Nur für Tests: hebt die Platform-Guards auf, damit das über den
  /// MethodChannel gesendete JSON auch auf dem Host geprüft werden kann.
  @visibleForTesting
  static bool debugBypassPlatformChecks = false;

  /// Nur für Tests: überschreibt, ob als Release-Build gerechnet wird.
  @visibleForTesting
  static bool? debugReleaseMode;

  bool get _isRelease => debugReleaseMode ?? kReleaseMode;

  /// Dev-Paket (`.dev`) in einem Release-Build ohne ausdrückliche Freigabe.
  bool _devGesperrt(bool isDevAndroid) =>
      isDevAndroid &&
      _isRelease &&
      !GptomSecurityConfig.current.allowDevPackageInRelease;

  /// Argumente für Bind- und Prüfaufrufe. Ein ungültiger Pin wirft
  /// [ArgumentError] – lieber laut scheitern als stillschweigend ohne Pin.
  Map<String, Object?> _sicherheitsArgs(bool isDevAndroid) {
    final config = GptomSecurityConfig.current;
    return {
      'isDev': isDevAndroid,
      'trustedSignatures': config.normalizedSignaturesAndroid,
      'verifySignature': config.verifySignatureAndroid,
    };
  }

  void _requireAndroid(String method) {
    if (debugBypassPlatformChecks) {
      return;
    }
    if (!Platform.isAndroid) {
      throw PlatformException(
        code: 'PlatformError',
        message: '$method is only supported on Android',
      );
    }
  }

  @override
  Future<bool> existGpTomApp({bool isDevAndroid = false}) async {
    if (Platform.isIOS) {
      Uri uri = Uri.parse("gptom://");
      return await canLaunchUrl(uri);
    }
    return await methodChannel.invokeMethod<bool>('existGpTomApp', {
      'isDev': isDevAndroid,
    }) ?? false;
  }

  @override
  Future<bool> openApp({bool isDevAndroid = false}) async {
    try {
      if (Platform.isIOS) {
        return await GptomAidlPluginIOS.openApp();
      }
      if (_devGesperrt(isDevAndroid)) {
        return false;
      }
      return await methodChannel.invokeMethod<bool>(
              'openGptomApp', _sicherheitsArgs(isDevAndroid)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<GptomAppCheck> checkGpTomApp({bool isDevAndroid = false}) async {
    if (Platform.isIOS) {
      final installed = await canLaunchUrl(Uri.parse('gptom://'));
      return GptomAppCheck(
        installed: installed,
        trusted: installed,
        source: installed
            ? GptomTrustSource.notApplicable
            : GptomTrustSource.notInstalled,
      );
    }
    if (_devGesperrt(isDevAndroid)) {
      return GptomAppCheck(
        installed: await existGpTomApp(isDevAndroid: true),
        trusted: false,
        source: GptomTrustSource.devPackageBlocked,
      );
    }
    final args = _sicherheitsArgs(isDevAndroid);
    final raw = await methodChannel.invokeMethod<Map>('checkGpTomApp', args);
    if (raw == null) {
      return const GptomAppCheck(
        installed: false,
        trusted: false,
        source: GptomTrustSource.notInstalled,
      );
    }
    return GptomAppCheck.fromMap(raw);
  }

  @override
  Future<bool> resetTrustedSignature({bool isDevAndroid = false}) async {
    if (Platform.isIOS) {
      return false;
    }
    return await methodChannel.invokeMethod<bool>('resetTrustedSignature', {
      'isDev': isDevAndroid,
    }) ?? false;
  }

  @override
  Future<bool> bindService({bool isDevAndroid = false}) async {
    if (Platform.isIOS) {
      return true;
    }
    if (_devGesperrt(isDevAndroid)) {
      return false;
    }
    return await methodChannel.invokeMethod<bool>(
            'bindService', _sicherheitsArgs(isDevAndroid)) ??
        false;
  }

  @override
  Future<void> unbindService() async {
    if (!Platform.isAndroid) {
      return;
    }
    await methodChannel.invokeMethod('unbindService');
  }

  @override
  Future<RegisterResult> registerTransactionV2Android(Map<String, dynamic> params) async {
    _requireAndroid('registerTransactionV2Android');
    final jsonParams = jsonEncode(params);
    final String? result;
    try {
      result = await methodChannel.invokeMethod<String>('registerTransactionV2', {
        'registerJson': jsonParams,
      });
    } on PlatformException catch (e) {
      // Der native Wächter meldet, dass GP tom nicht geantwortet hat.
      if (e.code == GptomErrorCode.timeout) {
        return RegisterResult(resultCode: GptomResultCode.timeout);
      }
      rethrow;
    }

    if (result == null) {
      return RegisterResult.formatException();
    }

    return RegisterResult.fromJson(result);
  }

  @override
  Future<RequestResult> requestTransactionV2Android(Map<String, dynamic> params) async {
    _requireAndroid('requestTransactionV2Android');
    final jsonParams = jsonEncode(params);
    final String? result;
    try {
      result = await methodChannel.invokeMethod<String>('requestTransactionV2', {
        'requestJson': jsonParams,
      });
    } on PlatformException catch (e) {
      // Der native Wächter meldet, dass GP tom nicht geantwortet hat. Das ist
      // ein Ergebnis, keine Ausnahme – und trägt denselben Code wie auf iOS.
      if (e.code == GptomErrorCode.timeout) {
        return RequestResult(
          result: GptomResultCode.timeout,
          responseMessage: e.message,
          error: ErrorInfo(
            errorCode: GptomErrorCode.timeout,
            result: GptomResultCode.timeout,
          ),
        );
      }
      rethrow;
    }
    if (result == null) {
      return RequestResult.exception();
    }
    return RequestResult.fromJson(result);
  }

  @override
  Future<StateResult> stateRequestAndroid(String transactionId) async {
    _requireAndroid('stateRequestAndroid');
    final dynamic raw = await methodChannel.invokeMethod<String>('stateRequest', {
      'transactionId': transactionId,
    });
    if (raw == null) {
      return StateResult.exception();
    }
    return StateResult.fromJson(raw);
  }

  @override
  Future<InquireResult> inquireTransactionAndroid(String transactionId) async {
    _requireAndroid('inquireTransactionAndroid');
    final dynamic raw = await methodChannel.invokeMethod<String>('inquireTransaction', {
      'transactionId': transactionId,
    });
    if (raw == null) {
      throw Exception('No result from inquireTransaction');
    }
    // Falls dein Native Code ein JSON-String liefert
    if (raw is String) {
      return InquireResult.fromJson(raw);
    }
    // Falls es ggf. ein Map ist:
    else if (raw is Map) {
      final map = Map<String, dynamic>.from(raw);
      return InquireResult.fromMap(map);
    }
    else {
      throw Exception('inquireTransaction: Unexpected type: $raw');
    }
  }

  // ---------------------------------------------------------------------------
  // Login-Service (AIDL 1.29.0)
  // ---------------------------------------------------------------------------
  @override
  Future<bool> bindLoginService({bool isDevAndroid = false}) async {
    _requireAndroid('bindLoginService');
    if (_devGesperrt(isDevAndroid)) {
      return false;
    }
    return await methodChannel.invokeMethod<bool>(
            'bindLoginService', _sicherheitsArgs(isDevAndroid)) ??
        false;
  }

  @override
  Future<void> unbindLoginService() async {
    if (!Platform.isAndroid) {
      return;
    }
    await methodChannel.invokeMethod('unbindLoginService');
  }

  @override
  Future<bool> loginGpTom({
    required String username,
    required String password,
    required String terminalId,
    String? authCode,
  }) async {
    _requireAndroid('loginGpTom');
    return await methodChannel.invokeMethod<bool>('gpTomLogin', {
      'username': username,
      'password': password,
      'terminalId': terminalId,
      'authCode': authCode,
    }) ?? false;
  }

  @override
  Future<bool> logoutGpTom() async {
    _requireAndroid('logoutGpTom');
    return await methodChannel.invokeMethod<bool>('gpTomLogout') ?? false;
  }

  @override
  Future<bool> changeGpTomPassword({
    required String currentPassword,
    required String newPassword,
    String? authCode,
    bool validationOnly = false,
  }) async {
    _requireAndroid('changeGpTomPassword');
    return await methodChannel.invokeMethod<bool>('gpTomChangePassword', {
      'oldPass': currentPassword,
      'newPass': newPassword,
      'authCode': authCode,
      'validationOnly': validationOnly,
    }) ?? false;
  }

  @override
  Stream<GpTomLoginEvent> get loginStatusStream => _loginStatusController.stream;

  // ---------------------------------------------------------------------------
  // Info-Service
  // ---------------------------------------------------------------------------
  @override
  Future<bool> bindInfoService({bool isDevAndroid = false}) async {
    _requireAndroid('bindInfoService');
    if (_devGesperrt(isDevAndroid)) {
      return false;
    }
    return await methodChannel.invokeMethod<bool>(
            'bindInfoService', _sicherheitsArgs(isDevAndroid)) ??
        false;
  }

  @override
  Future<void> unbindInfoService() async {
    if (!Platform.isAndroid) {
      return;
    }
    await methodChannel.invokeMethod('unbindInfoService');
  }

  @override
  Future<GpTomInfo?> getGpTomInfo({Duration? timeout}) async {
    _requireAndroid('getGpTomInfo');
    // Eine PlatformException mit Code TIMEOUT wird bewusst weitergereicht.
    final String? raw = await methodChannel.invokeMethod<String>(
      'getGpTomInfo',
      timeout == null ? null : {'timeoutMs': timeout.inMilliseconds},
    );
    if (raw == null) {
      return null;
    }
    return GpTomInfo.fromJson(raw);
  }

  @override
  Stream<GpTomInfo> get gpTomInfoStream => _gpTomInfoController.stream;

  @override
  Stream<RequestResult> get lateTransactionResultStream =>
      _lateTransactionController.stream;

  @override
  Future<bool> cancelTransactionIOS() async {
    if (!Platform.isIOS) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'cancelTransactionIOS is not supported on Android',
      );
    }
    throw UnimplementedError('cancelTransactionIOS is not implemented');
  }

  @override
  Future<bool> createTransactionIOS() async {
    if (!Platform.isIOS) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'createTransactionIOS is not supported on Android',
      );
    }
    return true;
  }
}
