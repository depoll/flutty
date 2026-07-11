/// A JSON object used by the Agent Client Protocol.
typedef AcpJsonMap = Map<String, Object?>;

/// Safe JSON conversion helpers used by ACP parsers.
abstract final class AcpJson {
  /// Returns [value] as a string-keyed JSON object, or `null`.
  static AcpJsonMap? object(Object? value) {
    if (value is! Map) return null;
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) result[key] = entry.value;
    }
    return result;
  }

  /// Returns [value] as a JSON list, or `null`.
  static List<Object?>? list(Object? value) {
    if (value is! List) return null;
    return List<Object?>.unmodifiable(value);
  }

  /// Returns a JSON string field.
  static String? string(AcpJsonMap json, String key) {
    final value = json[key];
    return value is String ? value : null;
  }

  /// Returns a JSON boolean field.
  static bool? boolean(AcpJsonMap json, String key) {
    final value = json[key];
    return value is bool ? value : null;
  }

  /// Returns a JSON integer field.
  static int? integer(AcpJsonMap json, String key) {
    final value = json[key];
    return value is int ? value : null;
  }

  /// Returns a JSON numeric field.
  static num? number(AcpJsonMap json, String key) {
    final value = json[key];
    return value is num ? value : null;
  }

  /// Returns a nested JSON object field.
  static AcpJsonMap? objectField(AcpJsonMap json, String key) =>
      object(json[key]);

  /// Returns a nested JSON list field.
  static List<Object?>? listField(AcpJsonMap json, String key) =>
      list(json[key]);

  /// Returns a list containing only valid string items.
  static List<String> strings(Object? value) {
    final values = list(value);
    if (values == null) return const <String>[];
    return List<String>.unmodifiable(values.whereType<String>());
  }

  /// Returns the reserved ACP `_meta` object.
  static AcpJsonMap meta(AcpJsonMap json) => Map<String, Object?>.unmodifiable(
    objectField(json, '_meta') ?? const <String, Object?>{},
  );

  /// Returns fields that are not recognized by the parser.
  static AcpJsonMap extensions(AcpJsonMap json, Iterable<String> knownFields) {
    final known = knownFields.toSet()..add('_meta');
    return Map<String, Object?>.unmodifiable(
      Map<String, Object?>.fromEntries(
        json.entries.where((entry) => !known.contains(entry.key)),
      ),
    );
  }

  /// Returns an immutable copy suitable for retaining unknown protocol data.
  static AcpJsonMap immutableObject(AcpJsonMap json) =>
      Map<String, Object?>.unmodifiable(json);
}

/// Shared extension data retained by forward-compatible ACP models.
abstract interface class AcpExtensible {
  /// ACP-reserved metadata that callers must treat as opaque.
  AcpJsonMap get meta;

  /// Unknown top-level fields retained by the parser.
  AcpJsonMap get extensions;
}
