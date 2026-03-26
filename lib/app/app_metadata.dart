import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

const _pullRequestNumber = String.fromEnvironment('FLUTTY_PR_NUMBER');
const _pullRequestTitle = String.fromEnvironment('FLUTTY_PR_TITLE');

/// Provides runtime app metadata for display in the UI.
final appMetadataProvider = FutureProvider<AppMetadata>((ref) async {
  final packageInfo = await PackageInfo.fromPlatform();

  return AppMetadata(
    version: packageInfo.version,
    buildNumber: packageInfo.buildNumber,
    pullRequestNumber: _normalizeBuildMetadata(_pullRequestNumber),
    pullRequestTitle: _normalizeBuildMetadata(_pullRequestTitle),
  );
});

/// Runtime and build metadata shown in settings and about surfaces.
class AppMetadata {
  /// Creates a new [AppMetadata].
  const AppMetadata({
    required this.version,
    required this.buildNumber,
    this.pullRequestNumber,
    this.pullRequestTitle,
  });

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
