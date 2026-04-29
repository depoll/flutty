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

  /// Whether SSID detection requires a runtime location-permission grant via
  /// `permission_handler` on the current platform. Only Android and iOS have
  /// a working `permission_handler` backend; on macOS the entitlement plus
  /// CoreLocation handles the first-use prompt natively when
  /// `network_info_plus` reads the SSID.
  static bool get _requiresLocationPermission =>
      isSupported &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

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
    value = _stripInvisibleCharacters(value).trim();
    if (value.isEmpty) return null;
    // Some platforms return placeholder strings when permissions are missing.
    if (value == '<unknown ssid>' || value == '0x') return null;
    return value;
  }
}

/// Removes characters that render as nothing — ASCII control codes (0x00–0x1F,
/// 0x7F), C1 control codes (0x80–0x9F), zero-width and bidi format characters
/// (Unicode general category Cf in the BMP), and the Unicode replacement
/// character. SSIDs containing only such characters would otherwise produce
/// blank chips in the editor and unmatchable storage values.
String _stripInvisibleCharacters(String value) {
  final buffer = StringBuffer();
  for (final rune in value.runes) {
    if (rune <= 0x1F || (rune >= 0x7F && rune <= 0x9F)) continue;
    // Cf characters (zero-width, bidi marks, joiners) plus the
    // U+FEFF byte order mark and the U+FFFD replacement character.
    if (rune == 0x00AD ||
        (rune >= 0x200B && rune <= 0x200F) ||
        (rune >= 0x2028 && rune <= 0x202F) ||
        (rune >= 0x2060 && rune <= 0x206F) ||
        rune == 0xFEFF ||
        rune == 0xFFFD) {
      continue;
    }
    buffer.writeCharCode(rune);
  }
  return buffer.toString();
}

/// Provider for [WifiNetworkService].
final wifiNetworkServiceProvider = Provider<WifiNetworkService>(
  (ref) => WifiNetworkService(),
);

/// Encodes a list of SSIDs to the storage format used in the Hosts table.
///
/// Newline-separated so SSIDs may legally contain commas, spaces, and most
/// other printable characters. Embedded `\n`/`\r` characters (which can sneak
/// in via paste) are stripped so they cannot corrupt the on-disk format.
String? encodeSkipJumpHostSsids(Iterable<String> ssids) {
  final cleaned = <String>[];
  final seen = <String>{};
  for (final ssid in ssids) {
    final sanitized = _sanitizeSsidForStorage(ssid);
    if (sanitized.isEmpty) continue;
    if (seen.add(sanitized)) {
      cleaned.add(sanitized);
    }
  }
  if (cleaned.isEmpty) return null;
  return cleaned.join('\n');
}

String _sanitizeSsidForStorage(String raw) =>
    _stripInvisibleCharacters(raw).trim();

/// Public helper used by UI code to normalize manual SSID entry to the same
/// rules the storage layer applies (strip invisibles + trim).
String sanitizeSsidInput(String raw) => _sanitizeSsidForStorage(raw);

/// Decodes the stored SSID list back into a list of unique entries.
///
/// Applies the same invisible-character stripping the encoder uses, so that
/// any pre-existing rows that contain control or zero-width characters
/// (e.g. SSIDs captured before the encoder hardening) come back clean.
List<String> decodeSkipJumpHostSsids(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  final result = <String>[];
  final seen = <String>{};
  for (final line in stored.split('\n')) {
    final sanitized = _sanitizeSsidForStorage(line);
    if (sanitized.isEmpty) continue;
    if (seen.add(sanitized)) {
      result.add(sanitized);
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
