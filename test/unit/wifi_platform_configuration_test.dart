import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Wi-Fi SSID platform configuration', () {
    test('android declares Wi-Fi SSID permissions', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();

      expect(manifest, contains('android.permission.ACCESS_WIFI_STATE'));
      expect(manifest, contains('android.permission.ACCESS_FINE_LOCATION'));
    });

    test('ios enables Wi-Fi SSID entitlement and location prompt', () {
      final entitlements = File(
        'ios/Runner/Runner.entitlements',
      ).readAsStringSync();
      final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();
      final podfile = File('ios/Podfile').readAsStringSync();

      expect(
        entitlements,
        contains('com.apple.developer.networking.wifi-info'),
      );
      expect(infoPlist, contains('NSLocationWhenInUseUsageDescription'));
      expect(podfile, contains('PERMISSION_LOCATION_WHENINUSE=1'));
    });
  });
}
