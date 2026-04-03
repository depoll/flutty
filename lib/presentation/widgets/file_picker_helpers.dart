import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

const _defaultFileBaseName = 'monkeyssh-transfer';

/// Normalizes a suggested export filename into a filesystem-safe base.
String sanitizeTransferFileBaseName(String input) {
  final normalized = input
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp('-+'), '-')
      .replaceAll(RegExp(r'^\.+|\.+$'), '')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return normalized.isEmpty ? _defaultFileBaseName : normalized;
}

/// Returns the native picker type to use for custom-extension files.
FileType pickerFileTypeForCustomExtension(TargetPlatform platform) =>
    platform == TargetPlatform.iOS ? FileType.any : FileType.custom;

/// Returns the picker extension filter for a custom-extension file selection.
List<String>? pickerAllowedExtensionsForCustomExtension(
  TargetPlatform platform,
  List<String> allowedExtensions,
) => platform == TargetPlatform.iOS ? null : allowedExtensions;

/// Returns whether the selected [file] matches [expectedExtension].
bool platformFileMatchesExpectedExtension(
  PlatformFile file,
  String expectedExtension,
) {
  final normalizedExpectedExtension = expectedExtension
      .toLowerCase()
      .replaceFirst(RegExp(r'^\.'), '');
  final extensionCandidates = <String?>[
    file.extension,
    p.extension(file.name),
    if (file.path case final path?) p.extension(path),
  ];
  return extensionCandidates
      .whereType<String>()
      .map(
        (extension) => extension.toLowerCase().replaceFirst(RegExp(r'^\.'), ''),
      )
      .any((extension) => extension == normalizedExpectedExtension);
}
