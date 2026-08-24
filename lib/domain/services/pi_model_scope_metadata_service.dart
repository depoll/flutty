import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'acp_client_capability_service.dart';
import 'remote_file_service.dart';

/// Maximum Pi settings payload inspected for model-scope metadata.
const int kPiModelScopeSettingsMaxBytes = 128 * 1024;

/// Maximum number of scoped-model patterns accepted from Pi settings.
const int kPiModelScopeMaxPatterns = 256;

/// Maximum length of one scoped-model pattern.
const int kPiModelScopeMaxPatternChars = 1024;

/// Reads only Pi's bounded `enabledModels` metadata over an existing SFTP
/// connection. Other settings are decoded transiently and never retained.
final class PiModelScopeMetadataService {
  /// Creates the metadata reader.
  const PiModelScopeMetadataService();

  /// Returns effective Pi model patterns, or `null` when no valid scope exists.
  ///
  /// Project-local `.pi/settings.json` replaces the global value when it
  /// contains a valid `enabledModels` field, matching Pi's settings precedence.
  Future<List<String>?> load(SftpClient sftp, {String? cwd}) async {
    try {
      final home = normalizeSftpAbsolutePath(await sftp.absolute('.'));
      if (home == null) {
        return null;
      }
      final fileSystem = AcpSftpRemoteFileSystem(() async => sftp);
      final global = await _read(
        fileSystem,
        joinRemotePath(home, '.pi/agent/settings.json'),
      );
      final projectDirectory = _resolveCwd(home, cwd);
      if (projectDirectory != null) {
        final project = await _read(
          fileSystem,
          joinRemotePath(projectDirectory, '.pi/settings.json'),
        );
        if (project.present) {
          return project.patterns;
        }
      }
      return global.present ? global.patterns : null;
    } on Object {
      // Model filtering is optional UI metadata. Missing, inaccessible, or
      // malformed settings must never prevent the live ACP session rendering.
      return null;
    }
  }

  Future<PiEnabledModelsMetadata> _read(
    AcpSftpRemoteFileSystem fileSystem,
    String path,
  ) async {
    try {
      final bytes = await fileSystem.read(
        path,
        maxBytes: kPiModelScopeSettingsMaxBytes,
      );
      return decodePiEnabledModels(utf8.decode(bytes));
    } on Object {
      return const PiEnabledModelsMetadata.absent();
    }
  }

  String? _resolveCwd(String home, String? cwd) {
    final value = cwd?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    if (value == '~') {
      return home;
    }
    if (value.startsWith('~/')) {
      return joinRemotePath(home, value.substring(2));
    }
    return normalizeSftpAbsolutePath(value);
  }
}

/// Extracts a valid, bounded `enabledModels` value from Pi settings JSON.
PiEnabledModelsMetadata decodePiEnabledModels(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?> ||
        !decoded.containsKey('enabledModels')) {
      return const PiEnabledModelsMetadata.absent();
    }
    final value = decoded['enabledModels'];
    if (value is! List || value.length > kPiModelScopeMaxPatterns) {
      return const PiEnabledModelsMetadata.absent();
    }
    final patterns = <String>[];
    for (final item in value) {
      if (item is! String) {
        return const PiEnabledModelsMetadata.absent();
      }
      final pattern = item.trim();
      if (pattern.isEmpty || pattern.length > kPiModelScopeMaxPatternChars) {
        return const PiEnabledModelsMetadata.absent();
      }
      patterns.add(pattern);
    }
    return PiEnabledModelsMetadata.present(List<String>.unmodifiable(patterns));
  } on Object {
    return const PiEnabledModelsMetadata.absent();
  }
}

/// Presence-aware result for one Pi settings file.
final class PiEnabledModelsMetadata {
  /// Creates a result for a missing or malformed field.
  const PiEnabledModelsMetadata.absent() : present = false, patterns = null;

  /// Creates a result for a valid field, including an explicitly empty list.
  const PiEnabledModelsMetadata.present(this.patterns) : present = true;

  /// Whether the settings file supplied a valid field.
  final bool present;

  /// Validated patterns when [present] is true.
  final List<String>? patterns;
}

/// Resolves Pi `enabledModels` patterns against ACP `provider/modelId` values.
///
/// This mirrors Pi's relevant scope behavior: case-insensitive exact/fuzzy
/// references, minimatch-style `*`, `?`, and character classes against both
/// the provider-qualified value and bare model id, ordered de-duplication, and
/// optional thinking-level suffixes.
List<String> resolvePiScopedModelIds({
  required List<String> patterns,
  required List<String> availableModelIds,
  Map<String, String> modelNames = const <String, String>{},
}) {
  final models = <_PiModelReference>[
    for (final value in availableModelIds)
      ?_PiModelReference.tryParse(value, modelNames[value]),
  ];
  final resolved = <String>[];
  final seen = <String>{};

  void add(_PiModelReference model) {
    if (seen.add(model.value.toLowerCase())) {
      resolved.add(model.value);
    }
  }

  for (final rawPattern in patterns) {
    var pattern = rawPattern.trim();
    if (pattern.isEmpty) {
      continue;
    }
    final hasGlob = _containsGlob(pattern);
    if (hasGlob) {
      pattern = _withoutThinkingSuffix(pattern);
      final exact = _findExact(pattern, models);
      if (exact != null) {
        add(exact);
        continue;
      }
      for (final model in models) {
        if (_minimatch(model.value, pattern) || _minimatch(model.id, pattern)) {
          add(model);
        }
      }
      continue;
    }

    var match = _findExact(pattern, models) ?? _findFuzzy(pattern, models);
    if (match == null) {
      final withoutThinking = _withoutThinkingSuffix(pattern);
      if (withoutThinking != pattern) {
        match =
            _findExact(withoutThinking, models) ??
            _findFuzzy(withoutThinking, models);
      }
    }
    if (match != null) {
      add(match);
    }
  }
  return List<String>.unmodifiable(resolved);
}

const _piThinkingLevels = <String>{
  'off',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
};

String _withoutThinkingSuffix(String pattern) {
  final separator = pattern.lastIndexOf(':');
  if (separator <= 0) {
    return pattern;
  }
  final suffix = pattern.substring(separator + 1).toLowerCase();
  return _piThinkingLevels.contains(suffix)
      ? pattern.substring(0, separator)
      : pattern;
}

bool _containsGlob(String pattern) =>
    pattern.contains('*') || pattern.contains('?') || pattern.contains('[');

_PiModelReference? _findExact(String pattern, List<_PiModelReference> models) {
  final normalized = pattern.toLowerCase();
  final canonical = models
      .where((model) => model.value.toLowerCase() == normalized)
      .toList(growable: false);
  if (canonical.length == 1) {
    return canonical.single;
  }
  final bare = models
      .where((model) => model.id.toLowerCase() == normalized)
      .toList(growable: false);
  return bare.length == 1 ? bare.single : null;
}

_PiModelReference? _findFuzzy(String pattern, List<_PiModelReference> models) {
  final normalized = pattern.toLowerCase();
  final matches = models
      .where(
        (model) =>
            model.id.toLowerCase().contains(normalized) ||
            model.name.toLowerCase().contains(normalized),
      )
      .toList(growable: false);
  if (matches.isEmpty) {
    return null;
  }
  final aliases = matches.where((model) => model.isAlias).toList();
  final candidates = aliases.isNotEmpty ? aliases : matches;
  return (candidates..sort((a, b) => b.id.compareTo(a.id))).first;
}

bool _minimatch(String value, String glob) {
  final pattern = StringBuffer('^');
  for (var index = 0; index < glob.length; index++) {
    final character = glob[index];
    if (character == '*') {
      if (index + 1 < glob.length && glob[index + 1] == '*') {
        pattern.write('.*');
        index++;
      } else {
        pattern.write('[^/]*');
      }
    } else if (character == '?') {
      pattern.write('[^/]');
    } else if (character == '[') {
      final end = glob.indexOf(']', index + 1);
      if (end > index + 1) {
        var contents = glob.substring(index + 1, end);
        if (contents.startsWith('!')) {
          contents = '^${contents.substring(1)}';
        }
        pattern.write('[$contents]');
        index = end;
      } else {
        pattern.write(r'\[');
      }
    } else {
      pattern.write(RegExp.escape(character));
    }
  }
  pattern.write(r'$');
  try {
    return RegExp(pattern.toString(), caseSensitive: false).hasMatch(value);
  } on FormatException {
    return false;
  }
}

final class _PiModelReference {
  const _PiModelReference({
    required this.value,
    required this.id,
    required this.name,
  });

  static _PiModelReference? tryParse(String value, String? name) {
    final separator = value.indexOf('/');
    if (separator <= 0 || separator == value.length - 1) {
      return null;
    }
    final id = value.substring(separator + 1);
    final displayName = (name ?? id).trim();
    final nameSeparator = displayName.indexOf('/');
    return _PiModelReference(
      value: value,
      id: id,
      name: nameSeparator >= 0
          ? displayName.substring(nameSeparator + 1)
          : displayName,
    );
  }

  final String value;
  final String id;
  final String name;

  bool get isAlias =>
      id.endsWith('-latest') || !RegExp(r'-\d{8}$').hasMatch(id);
}
