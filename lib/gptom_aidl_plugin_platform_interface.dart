import 'package:gptom_aidl_plugin/models/inquire_result.dart';
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
  Future<bool> bindService({bool isDevAndroid = false});
  Future<RegisterResult> registerTransactionV2Android(Map<String, dynamic> params);
  Future<RequestResult> requestTransactionV2Android(Map<String, dynamic> params);
  Future<StateResult> stateRequestAndroid(String transactionId);
  Future<InquireResult> inquireTransactionAndroid(String transactionId);
  Future<bool> createTransactionIOS();
  Future<bool> cancelTransactionIOS();
}
