const _preferredGeneratedPortProxySlugLength = 12;
const _maximumDnsLabelLength = 63;

/// Builds the complete normalized base used by generated proxy aliases.
String normalizedPortProxySlug(String hostLabel) {
  var base = hostLabel
      .trim()
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (base.isEmpty) {
    base = 'host';
  }
  return base;
}

/// Builds the short readable default used by generated proxy aliases.
String generatedPortProxySlug(String hostLabel) => _portProxySlugPrefix(
  normalizedPortProxySlug(hostLabel),
  _preferredGeneratedPortProxySlugLength,
);

/// Resolves collision-free generated names for a set of saved hosts.
///
/// Different normalized names extend beyond the preferred short prefix only as
/// far as needed. Numeric IDs are reserved for true duplicate normalized names
/// or the rare case where names remain indistinguishable at the DNS limit.
Map<int, String> resolveGeneratedPortProxyNames(
  Iterable<({int id, String label})> hosts,
) {
  final normalizedById = <int, String>{
    for (final host in hosts) host.id: normalizedPortProxySlug(host.label),
  };
  final normalizedCounts = <String, int>{};
  for (final normalized in normalizedById.values) {
    normalizedCounts.update(
      normalized,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  final resolved = <int, String>{};
  final prefixLengths = <int, int>{};
  for (final entry in normalizedById.entries) {
    if (normalizedCounts[entry.value]! > 1) {
      resolved[entry.key] = _portProxySlugWithHostId(entry.value, entry.key);
    } else {
      prefixLengths[entry.key] = entry.value.length.clamp(
        1,
        _preferredGeneratedPortProxySlugLength,
      );
    }
  }

  while (prefixLengths.isNotEmpty) {
    final candidates = <int, String>{
      for (final entry in prefixLengths.entries)
        entry.key: _portProxySlugPrefix(
          normalizedById[entry.key]!,
          entry.value,
        ),
    };
    final candidateCounts = <String, int>{};
    for (final name in [...resolved.values, ...candidates.values]) {
      candidateCounts.update(name, (count) => count + 1, ifAbsent: () => 1);
    }

    final completedIds = <int>[];
    for (final entry in candidates.entries) {
      if (candidateCounts[entry.value] == 1) {
        resolved[entry.key] = entry.value;
        completedIds.add(entry.key);
        continue;
      }

      final normalized = normalizedById[entry.key]!;
      final nextLength = _nextDistinctPrefixLength(
        normalized,
        currentLength: prefixLengths[entry.key]!,
        currentPrefix: entry.value,
      );
      if (nextLength == null) {
        resolved[entry.key] = _portProxySlugWithHostId(entry.value, entry.key);
        completedIds.add(entry.key);
      } else {
        prefixLengths[entry.key] = nextLength;
      }
    }
    for (final id in completedIds) {
      prefixLengths.remove(id);
    }
  }

  return Map.unmodifiable(resolved);
}

int? _nextDistinctPrefixLength(
  String normalized, {
  required int currentLength,
  required String currentPrefix,
}) {
  final maximumLength = normalized.length.clamp(1, _maximumDnsLabelLength);
  for (var length = currentLength + 1; length <= maximumLength; length++) {
    if (_portProxySlugPrefix(normalized, length) != currentPrefix) {
      return length;
    }
  }
  return null;
}

String _portProxySlugWithHostId(String slug, int hostId) {
  final suffix = '-$hostId';
  final maximumBaseLength = _maximumDnsLabelLength - suffix.length;
  return '${_portProxySlugPrefix(slug, maximumBaseLength)}$suffix';
}

String _portProxySlugPrefix(String normalized, int maximumLength) {
  if (normalized.length <= maximumLength) {
    return normalized;
  }
  return normalized
      .substring(0, maximumLength)
      .replaceFirst(RegExp(r'-+$'), '');
}
