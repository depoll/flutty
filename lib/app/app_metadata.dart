import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Default app name used while platform metadata is still loading.
const defaultAppName = 'MonkeySSH';

const _pullRequestNumber = String.fromEnvironment('FLUTTY_PR_NUMBER');
const _pullRequestTitle = String.fromEnvironment('FLUTTY_PR_TITLE');

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
    this.pullRequestNumber,
    this.pullRequestTitle,
  });

  /// Human-visible app name for the current bundle/flavor.
  final String appName;

  /// Human-visible app version name.
  final String version;

  /// Platform build number for the current app bundle.
  final String buildNumber;

  /// Pull request number for preview-derived builds, when present.
  final String? pullRequestNumber;

  /// Pull request title for preview-derived builds, when present.
  final String? pullRequestTitle;

  /// Combined version/build label for settings and license UI.
  String get versionLabel => '$version ($buildNumber)';

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
}

String? _normalizeBuildMetadata(String value) {
  final trimmedValue = value.trim();
  if (trimmedValue.isEmpty) {
    return null;
  }

  return trimmedValue;
}

/// Normalizes a platform app name and falls back to [defaultAppName].
String normalizeAppName(String value) {
  final trimmedValue = value.trim();
  if (trimmedValue.isEmpty) {
    return defaultAppName;
  }

  return trimmedValue;
}
