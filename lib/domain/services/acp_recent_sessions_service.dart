import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_recent_session.dart';
import '../models/acp_session_keys.dart';
import 'settings_service.dart';

/// Persists non-content references to recently used ACP sessions and the last
/// selected session through [SettingsService].
///
/// This service only ever stores host/provider/bridge/session identifiers, an
/// optional title and working directory, and activity timestamps. It never
/// reads, logs, or persists prompts, messages, attachments, tool data, or
/// reasoning. Malformed storage is handled defensively and all mutations are
/// serialized so overlapping writes cannot drop one another's changes.
class AcpRecentSessionsService {
  /// Creates a recent-sessions service.
  AcpRecentSessionsService(this._settings, {int maxEntries = defaultMaxEntries})
    : _maxEntries = maxEntries;

  /// Default maximum number of retained recent-session references.
  static const defaultMaxEntries = 50;

  final SettingsService _settings;
  final int _maxEntries;

  // Serializes every read-modify-write cycle so two overlapping mutations can
  // never both read the same starting list and silently discard a change.
  Future<void> _mutationQueue = Future<void>.value();

  /// Loads all persisted recent-session references, most recent first.
  ///
  /// Entries that fail to parse are skipped rather than surfaced as an error.
  Future<List<AcpRecentSessionRef>> list() async {
    final raw = await _settings.getString(SettingKeys.acpRecentSessions);
    return _decode(raw);
  }

  /// Streams the persisted recent-session references, re-emitting whenever
  /// storage changes.
  Stream<List<AcpRecentSessionRef>> watch() =>
      _settings.watchString(SettingKeys.acpRecentSessions).map(_decode);

  /// Inserts or updates [ref], moving it to the front and bounding the list.
  ///
  /// A reference with the same [AcpSessionKey] replaces the previous entry so
  /// updated titles and timestamps are retained without duplication.
  Future<void> record(AcpRecentSessionRef ref) => _withMutationLock(() async {
    final existing = await list();
    final deduped = existing
        .where((entry) => entry.key != ref.key)
        .toList(growable: true);
    final updated = <AcpRecentSessionRef>[ref, ...deduped];
    final bounded = updated.length > _maxEntries
        ? updated.sublist(0, _maxEntries)
        : updated;
    await _write(bounded);
  });

  /// Removes the reference identified by [key], if present.
  Future<void> remove(AcpSessionKey key) => _withMutationLock(() async {
    final existing = await list();
    final updated = existing
        .where((entry) => entry.key != key)
        .toList(growable: false);
    if (updated.length == existing.length) return;
    await _write(updated);
  });

  /// Removes every persisted recent-session reference.
  Future<void> clear() => _withMutationLock(() async {
    await _settings.delete(SettingKeys.acpRecentSessions);
  });

  /// Loads the last selected session key, or `null` when none is stored.
  Future<AcpSessionKey?> getLastSelected() async {
    final raw = await _settings.getString(SettingKeys.acpLastSelectedSession);
    return _decodeKey(raw);
  }

  /// Streams the last selected session key.
  Stream<AcpSessionKey?> watchLastSelected() =>
      _settings.watchString(SettingKeys.acpLastSelectedSession).map(_decodeKey);

  /// Persists [key] as the last selected session, or clears it when `null`.
  Future<void> setLastSelected(AcpSessionKey? key) =>
      _withMutationLock(() async {
        if (key == null) {
          await _settings.delete(SettingKeys.acpLastSelectedSession);
          return;
        }
        await _settings.setString(
          SettingKeys.acpLastSelectedSession,
          jsonEncode(<String, Object?>{
            'hostId': key.hostId,
            'providerId': key.providerId,
            'bridgeId': key.bridgeId,
            'acpSessionId': key.acpSessionId,
          }),
        );
      });

  Future<void> _write(List<AcpRecentSessionRef> refs) async {
    if (refs.isEmpty) {
      await _settings.delete(SettingKeys.acpRecentSessions);
      return;
    }
    await _settings.setString(
      SettingKeys.acpRecentSessions,
      jsonEncode([for (final ref in refs) ref.toJson()]),
    );
  }

  Future<void> _withMutationLock(Future<void> Function() action) {
    final operation = _mutationQueue.then((_) => action());
    _mutationQueue = operation.catchError((_) {});
    return operation;
  }

  List<AcpRecentSessionRef> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    final refs = <AcpRecentSessionRef>[];
    for (final item in decoded) {
      final ref = AcpRecentSessionRef.tryFromJson(item);
      if (ref != null) refs.add(ref);
      if (refs.length >= _maxEntries) break;
    }
    return List.unmodifiable(refs);
  }

  AcpSessionKey? _decodeKey(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final hostId = decoded['hostId'];
    final providerId = decoded['providerId'];
    final bridgeId = decoded['bridgeId'];
    final acpSessionId = decoded['acpSessionId'];
    if (hostId is! int ||
        providerId is! String ||
        providerId.isEmpty ||
        bridgeId is! String ||
        bridgeId.isEmpty ||
        acpSessionId is! String ||
        acpSessionId.isEmpty) {
      return null;
    }
    return AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
    );
  }
}

/// Provider for [AcpRecentSessionsService].
final acpRecentSessionsServiceProvider = Provider<AcpRecentSessionsService>(
  (ref) => AcpRecentSessionsService(ref.watch(settingsServiceProvider)),
);

/// Streams persisted recent ACP session references.
final acpRecentSessionsProvider = StreamProvider<List<AcpRecentSessionRef>>(
  (ref) => ref.watch(acpRecentSessionsServiceProvider).watch(),
);
