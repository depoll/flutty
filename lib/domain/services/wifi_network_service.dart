import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'diagnostics_log_service.dart';

/// Reads the current Wi-Fi SSID, where supported by the platform.
///
/// Returns `null` when the platform cannot report the SSID, when the device is
/// not on Wi-Fi, or when the necessary OS permissions have not been granted.
class WifiNetworkService {
  /// Creates a new [WifiNetworkService].
  WifiNetworkService({NetworkInfo? networkInfo})
    : _networkInfo = networkInfo ?? NetworkInfo();

  final NetworkInfo _networkInfo;

  /// Whether SSID detection is supported on the current platform at all.
  ///
  /// `network_info_plus` only returns SSIDs on iOS, Android, and macOS. Web
  /// and desktop platforms return `null` rather than prompting for
  /// unavailable permissions.
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// Whether SSID detection requires a runtime location-permission grant on
  /// the current platform. Android requires `ACCESS_FINE_LOCATION`; iOS and
  /// macOS only need it when the app does not hold the
  /// `com.apple.developer.networking.wifi-info` entitlement, but requesting
  /// it lets us recover when the entitlement is missing in development
  /// builds, so we still ask there.
  static bool get _requiresLocationPermission =>
      isSupported &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  /// Result of a permission request, surfaced to the UI so it can guide the
  /// user to Settings when the OS has permanently denied access.
  Future<WifiPermissionStatus> requestPermission() async {
    if (!_requiresLocationPermission) {
      return WifiPermissionStatus.granted;
    }
    final status = await Permission.locationWhenInUse.request();
    if (status.isGranted || status.isLimited) {
      return WifiPermissionStatus.granted;
    }
    if (status.isPermanentlyDenied) {
      return WifiPermissionStatus.permanentlyDenied;
    }
    return WifiPermissionStatus.denied;
  }

  /// Returns the current Wi-Fi SSID, or `null` if unavailable.
  ///
  /// The raw value from the platform may be wrapped in quotes (`"my-ssid"`),
  /// which this method strips. Errors and missing permissions are swallowed
  /// and reported as `null` so callers can treat them as "not on a known
  /// network".
  Future<String?> getCurrentSsid() async {
    if (!isSupported) {
      return null;
    }
    try {
      final raw = await _networkInfo.getWifiName();
      return _normalizeSsid(raw);
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'wifi.ssid',
        'lookup_failed',
        fields: {'errorType': error.runtimeType.toString()},
      );
      return null;
    }
  }

  static String? _normalizeSsid(String? raw) {
    if (raw == null) return null;
    var value = raw.trim();
    if (value.isEmpty) return null;
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    value = value.trim();
    if (value.isEmpty) return null;
    // Some platforms return placeholder strings when permissions are missing.
    if (value == '<unknown ssid>' || value == '0x') return null;
    return value;
  }
}

/// Provider for [WifiNetworkService].
final wifiNetworkServiceProvider = Provider<WifiNetworkService>(
  (ref) => WifiNetworkService(),
);

/// Encodes a list of SSIDs to the storage format used in the Hosts table.
///
/// Newline-separated so SSIDs may legally contain commas, spaces, and most
/// other printable characters.
String? encodeSkipJumpHostSsids(Iterable<String> ssids) {
  final cleaned = <String>[];
  final seen = <String>{};
  for (final ssid in ssids) {
    final trimmed = ssid.trim();
    if (trimmed.isEmpty) continue;
    if (seen.add(trimmed)) {
      cleaned.add(trimmed);
    }
  }
  if (cleaned.isEmpty) return null;
  return cleaned.join('\n');
}

/// Decodes the stored SSID list back into a list of unique entries.
List<String> decodeSkipJumpHostSsids(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final line in stored.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (seen.add(trimmed)) {
      result.add(trimmed);
    }
  }
  return result;
}

/// Returns `true` if [currentSsid] is in the host's skip list.
///
/// The match is case-sensitive. Wi-Fi SSIDs are technically case-sensitive
/// at the 802.11 layer and the platform APIs return the exact bytes the
/// router advertises, so this preserves user intent (e.g. distinguishing
/// `home` from `Home` if a user really set up two networks).
bool shouldSkipJumpHostForSsid({
  required String? currentSsid,
  required String? skipJumpHostOnSsids,
}) {
  if (currentSsid == null) return false;
  final list = decodeSkipJumpHostSsids(skipJumpHostOnSsids);
  if (list.isEmpty) return false;
  return list.contains(currentSsid);
}

/// Outcome of a permission request, used by the UI to differentiate a
/// "tap again" denial from one that requires going to system Settings.
enum WifiPermissionStatus {
  /// Permission granted (or not required on this platform).
  granted,

  /// Permission was denied this time but can be re-requested.
  denied,

  /// Permission was permanently denied; user must change it in Settings.
  permanentlyDenied,
}
