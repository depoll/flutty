import 'package:flutter/foundation.dart';

final _schemeIdNonWordPattern = RegExp('[^a-z0-9]+');

/// Builds the local terminal theme ID for an iTerm2 color scheme name.
String buildItermColorSchemeThemeId(String schemeName) {
  final normalized = schemeName.replaceAll('+', ' plus ').toLowerCase();
  final slug = normalized
      .replaceAll(_schemeIdNonWordPattern, '-')
      .replaceAll(RegExp('-{2,}'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  if (slug.isEmpty) {
    return 'iterm2-theme';
  }
  return 'iterm2-$slug';
}

/// Metadata for a live iTerm2-Color-Schemes repository entry.
@immutable
class ItermColorSchemeMetadata {
  /// Creates metadata for a live iTerm2 color scheme.
  const ItermColorSchemeMetadata({
    required this.id,
    required this.name,
    required this.path,
  });

  /// Creates metadata from a repository path under `schemes/`.
  factory ItermColorSchemeMetadata.fromPath(String path) {
    final filename = path.split('/').last;
    final name = filename.replaceFirst(RegExp(r'\.itermcolors$'), '');
    return ItermColorSchemeMetadata(
      id: buildItermColorSchemeThemeId(name),
      name: name,
      path: path,
    );
  }

  /// Stable local theme ID for this scheme.
  final String id;

  /// Display name from the upstream file name.
  final String name;

  /// Repository path for the upstream `.itermcolors` file.
  final String path;

  /// Raw GitHub URL for downloading the scheme plist.
  Uri get rawUri => Uri(
    scheme: 'https',
    host: 'raw.githubusercontent.com',
    pathSegments: [
      'mbadolato',
      'iTerm2-Color-Schemes',
      'master',
      ...path.split('/'),
    ],
  );
}
