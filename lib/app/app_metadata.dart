import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Default app name used while platform metadata is still loading.
const defaultAppName = 'MonkeySSH';
const _versionCodenameAssetPath = 'assets/version_codenames.json';

const _pullRequestNumber = String.fromEnvironment('FLUTTY_PR_NUMBER');
const _pullRequestTitle = String.fromEnvironment('FLUTTY_PR_TITLE');
const _diagnosticsBuildEnabled = bool.fromEnvironment(
  'FLUTTY_DIAGNOSTICS_ENABLED',
);
Future<Map<int, String>>? _versionCodenameLookup;

/// Whether this binary was produced from a pull-request preview build.
const isPreviewBuild = _pullRequestNumber != '';

/// Whether this binary should retain and expose diagnostics logs.
const isDiagnosticsLoggingEnabled = isPreviewBuild || _diagnosticsBuildEnabled;

/// Provides the current platform app name with a safe fallback.
final appDisplayNameProvider = Provider<String>((ref) {
  final appMetadata = ref.watch(appMetadataProvider);
  return appMetadata.maybeWhen(
    data: (value) => value.appName,
    orElse: () => defaultAppName,
  );
});

/// Provides runtime app metadata for display in the UI.
final appMetadataProvider = FutureProvider<AppMetadata>((ref) async {
  final packageInfo = await PackageInfo.fromPlatform();

  return AppMetadata(
    appName: normalizeAppName(packageInfo.appName),
    version: packageInfo.version,
    buildNumber: packageInfo.buildNumber,
    versionCodename: await _resolveVersionCodename(packageInfo.version),
    pullRequestNumber: _normalizeBuildMetadata(_pullRequestNumber),
    pullRequestTitle: _normalizeBuildMetadata(_pullRequestTitle),
  );
});

/// Reads the current platform app name.
Future<String> loadAppName() async {
  final packageInfo = await PackageInfo.fromPlatform();
  return normalizeAppName(packageInfo.appName);
}

/// Runtime and build metadata shown in settings and about surfaces.
class AppMetadata {
  /// Creates a new [AppMetadata].
  const AppMetadata({
    required this.appName,
    required this.version,
    required this.buildNumber,
    this.versionCodename,
    this.pullRequestNumber,
    this.pullRequestTitle,
  });

  /// Human-visible app name for the current bundle/flavor.
  final String appName;

  /// Human-visible app version name.
  final String version;

  /// Platform build number for the current app bundle.
  final String buildNumber;

  /// Monkey-themed codename associated with the current major version.
  final String? versionCodename;

  /// Pull request number for preview-derived builds, when present.
  final String? pullRequestNumber;

  /// Pull request title for preview-derived builds, when present.
  final String? pullRequestTitle;

  /// Human-visible version label including the major-version codename.
  String get marketingVersionLabel {
    final versionCodename = this.versionCodename;
    if (versionCodename == null) {
      return version;
    }

    return '$version "$versionCodename"';
  }

  /// Combined version/build label for settings and license UI.
  String get versionLabel => '$marketingVersionLabel ($buildNumber)';

  /// Human-friendly pull request label for preview/TestFlight deploys.
  String? get pullRequestLabel {
    final pullRequestNumber = this.pullRequestNumber;
    if (pullRequestNumber == null) {
      return null;
    }

    final pullRequestTitle = this.pullRequestTitle;
    if (pullRequestTitle == null) {
      return 'PR #$pullRequestNumber';
    }

    return 'PR #$pullRequestNumber: $pullRequestTitle';
  }

  /// Whether the runtime metadata identifies a pull-request preview build.
  bool get isPreviewBuild => pullRequestNumber != null;
}

String? _normalizeBuildMetadata(String value) {
  final trimmedValue = value.trim();
  if (trimmedValue.isEmpty) {
    return null;
  }

  return trimmedValue;
}

Future<String?> _resolveVersionCodename(String version) async {
  final majorVersion = _parseMajorVersion(version);
  if (majorVersion == null) {
    return null;
  }

  final versionCodenameLookup = await (_versionCodenameLookup ??=
      _loadVersionCodenameLookup());
  return versionCodenameLookup[majorVersion];
}

Future<Map<int, String>> _loadVersionCodenameLookup() async {
  final payload = jsonDecode(
    await rootBundle.loadString(_versionCodenameAssetPath),
  );
  final result = <int, String>{};

  if (payload case {'codenames': final List<dynamic> entries}) {
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }

      final majorVersion = entry['major'];
      final name = entry['name'];
      if (majorVersion is int && name is String) {
        final normalizedName = name.trim();
        if (normalizedName.isNotEmpty) {
          result[majorVersion] = normalizedName;
        }
      }
    }
  }

  return result;
}

int? _parseMajorVersion(String version) {
  final trimmedVersion = version.trim();
  if (trimmedVersion.isEmpty) {
    return null;
  }

  final segments = trimmedVersion.split('.');
  if (segments.isEmpty) {
    return null;
  }

  return int.tryParse(segments.first);
}

/// Normalizes a platform app name and falls back to [defaultAppName].
String normalizeAppName(String value) {
  final trimmedValue = value.trim();
  if (trimmedValue.isEmpty) {
    return defaultAppName;
  }

  return trimmedValue;
}
