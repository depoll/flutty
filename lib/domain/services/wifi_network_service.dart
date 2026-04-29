import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';

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
  /// `network_info_plus` only returns SSIDs on iOS, Android, and macOS. On
  /// other platforms (Windows, Linux, web) we always return `null` rather
  /// than prompting for unavailable permissions.
  static bool get isSupported {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
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
bool shouldSkipJumpHostForSsid({
  required String? currentSsid,
  required String? skipJumpHostOnSsids,
}) {
  if (currentSsid == null) return false;
  final list = decodeSkipJumpHostSsids(skipJumpHostOnSsids);
  if (list.isEmpty) return false;
  return list.contains(currentSsid);
}
