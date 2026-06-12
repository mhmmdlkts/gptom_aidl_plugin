import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptom_aidl_plugin/gptom_aidl_plugin_method_channel.dart';
import 'package:gptom_aidl_plugin/models/login_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();

  /// Simuliert einen Aufruf aus dem nativen Code (AIDL-Callback -> Dart).
  Future<void> pushNativeCall(MethodCall call) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'gptom_aidl_plugin',
      codec.encodeMethodCall(call),
      (_) {},
    );
  }

  group('Native Pushes', () {
    test('onLoginStatusChanged landet im loginStatusStream', () async {
      final platform = MethodChannelGptomAidlPlugin();

      final eventFuture = platform.loginStatusStream.first;
      await pushNativeCall(const MethodCall('onLoginStatusChanged', {
        'status': 'USER_LOGGED_IN',
        'message': 'Willkommen',
      }));

      final event = await eventFuture;
      expect(event.status, GpTomLoginStatus.userLoggedIn);
      expect(event.rawStatus, 'USER_LOGGED_IN');
      expect(event.message, 'Willkommen');
      expect(event.isLoggedIn, isTrue);
    });

    test('unbekannter Login-Status wird unknown, rawStatus bleibt erhalten', () async {
      final platform = MethodChannelGptomAidlPlugin();

      final eventFuture = platform.loginStatusStream.first;
      await pushNativeCall(const MethodCall('onLoginStatusChanged', {
        'status': 'BRAND_NEW_STATUS',
        'message': null,
      }));

      final event = await eventFuture;
      expect(event.status, GpTomLoginStatus.unknown);
      expect(event.rawStatus, 'BRAND_NEW_STATUS');
    });

    test('onGpTomInfoChanged landet im gpTomInfoStream', () async {
      final platform = MethodChannelGptomAidlPlugin();

      final infoFuture = platform.gpTomInfoStream.first;
      await pushNativeCall(MethodCall(
        'onGpTomInfoChanged',
        jsonEncode({
          'appVersion': '2.30.1',
          'isLoggedIn': true,
          'logInStatus': 'LOGGED_IN',
          'tid': '11263520',
          'mid': '000007311211351',
          'tipEnabled': true,
        }),
      ));

      final info = await infoFuture;
      expect(info.appVersion, '2.30.1');
      expect(info.isLoggedIn, isTrue);
      expect(info.logInStatus, 'LOGGED_IN');
      expect(info.tid, '11263520');
      expect(info.tipEnabled, isTrue);
      expect(info.raw['mid'], '000007311211351');
    });
  });
}
