import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Wi-Fi SSID platform configuration', () {
    test('android declares Wi-Fi SSID permissions', () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();

      expect(manifest, contains('android.permission.ACCESS_WIFI_STATE'));
      expect(manifest, contains('android.permission.ACCESS_COARSE_LOCATION'));
      expect(manifest, contains('android.permission.ACCESS_FINE_LOCATION'));
    });

    test('ios enables Wi-Fi SSID entitlement and location prompt', () {
      final entitlements = File(
        'ios/Runner/Runner.entitlements',
      ).readAsStringSync();
      final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

      expect(
        entitlements,
        contains('com.apple.developer.networking.wifi-info'),
      );
      expect(
        infoPlist,
        contains('NSLocationAlwaysAndWhenInUseUsageDescription'),
      );
      // permission_handler_apple's Package.swift derives its PERMISSION_*
      // macros from the host Info.plist, so this key is what compiles the
      // when-in-use location strategy into the plugin under Swift Package
      // Manager. Dropping it would silently disable Wi-Fi SSID lookup.
      expect(infoPlist, contains('NSLocationWhenInUseUsageDescription'));
      expect(infoPlist, contains('current Wi-Fi network name'));
    });
  });
}
