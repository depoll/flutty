// ignore_for_file: public_member_api_docs

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/background_ssh_service.dart';

const _backgroundSshChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/ssh_service',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundSshService battery optimization helpers', () {
    late List<MethodCall> methodCalls;
    var batteryOptimizationIgnored = false;
    var openedBatterySettings = false;

    setUp(() {
      methodCalls = <MethodCall>[];
      batteryOptimizationIgnored = false;
      openedBatterySettings = false;
      BackgroundSshService.debugIsAndroidPlatformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, (call) async {
            methodCalls.add(call);
            return switch (call.method) {
              'isBatteryOptimizationIgnored' => batteryOptimizationIgnored,
              'requestDisableBatteryOptimization' => openedBatterySettings,
              _ => null,
            };
          });
    });

    tearDown(() {
      BackgroundSshService.debugIsAndroidPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, null);
    });

    test('isBatteryOptimizationIgnored queries the native channel', () async {
      batteryOptimizationIgnored = true;

      final result = await BackgroundSshService.isBatteryOptimizationIgnored();

      expect(result, isTrue);
      expect(methodCalls, hasLength(1));
      expect(methodCalls.single.method, 'isBatteryOptimizationIgnored');
    });

    test(
      'requestDisableBatteryOptimization opens the native settings flow',
      () async {
        openedBatterySettings = true;

        final result =
            await BackgroundSshService.requestDisableBatteryOptimization();

        expect(result, isTrue);
        expect(methodCalls, hasLength(1));
        expect(methodCalls.single.method, 'requestDisableBatteryOptimization');
      },
    );

    test('unsupported platforms skip the native channel', () async {
      BackgroundSshService.debugIsAndroidPlatformOverride = false;

      final isIgnored =
          await BackgroundSshService.isBatteryOptimizationIgnored();
      final opened =
          await BackgroundSshService.requestDisableBatteryOptimization();

      expect(isIgnored, isTrue);
      expect(opened, isFalse);
      expect(methodCalls, isEmpty);
    });
  });
}
