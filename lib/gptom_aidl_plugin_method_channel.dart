import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_ios.dart';
import 'package:gptom_aidl_plugin/models/inquire_result.dart';
import 'package:gptom_aidl_plugin/models/request_result.dart';
import 'package:url_launcher/url_launcher.dart';

import 'gptom_aidl_plugin_platform_interface.dart';
import 'models/register_result.dart';
import 'models/state_result.dart';

class MethodChannelGptomAidlPlugin extends GptomAidlPluginPlatform {
  final methodChannel = const MethodChannel('gptom_aidl_plugin');
  final GptomAidlPluginIOS gptomAidlPluginIOS = GptomAidlPluginIOS();

  @override
  Future<bool> existGpTomApp({bool isDevAndroid = false}) async {
    if (Platform.isIOS) {
      Uri uri = Uri.parse("gptom://");
      return await canLaunchUrl(uri);
    }
    return await methodChannel.invokeMethod<bool>('existGpTomApp', {
      'isDev': isDevAndroid, // oder false
    }) ?? false;
  }

  @override
  Future<bool> bindService({bool isDevAndroid = false}) async {
    print('bbb: ${Platform.isIOS}');
    if (Platform.isIOS) {
      return true;
    }
    print('ccc');
    return await methodChannel.invokeMethod<bool>('bindService', {
      'isDev': isDevAndroid, // oder false
    }) ?? false;
  }

  @override
  Future<RegisterResult> registerTransactionV2Android(Map<String, dynamic> params) async {
    if (!Platform.isAndroid) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'registerTransactionV2Android is not supported on iOS',
      );
    }
    final jsonParams = jsonEncode(params);
    final String? result = await methodChannel.invokeMethod<String>('registerTransactionV2', {
      'registerJson': jsonParams,
    });

    if (result == null) {
      return RegisterResult.formatException();
    }

    return RegisterResult.fromJson(result);
  }

  @override
  Future<RequestResult> requestTransactionV2Android(Map<String, dynamic> params) async {
    if (!Platform.isAndroid) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'requestTransactionV2Android is not supported on iOS',
      );
    }
    final jsonParams = jsonEncode(params);
    final String? result = await methodChannel.invokeMethod<String>('requestTransactionV2', {
      'requestJson': jsonParams,
    });
    if (result == null) {
      return RequestResult.exception();
    }
    return RequestResult.fromJson(result);
  }

  @override
  Future<StateResult> stateRequestAndroid(String transactionId) async {
    if (!Platform.isAndroid) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'stateRequestAndroid is not supported on iOS',
      );
    }
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
    if (!Platform.isAndroid) {
      throw PlatformException(
        code: 'PlatformError',
        message: 'inquireTransactionAndroid is not supported on iOS',
      );
    }
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