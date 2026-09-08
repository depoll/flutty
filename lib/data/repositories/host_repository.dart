import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/port_proxy_name.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/diagnostics_log_service.dart';
import '../database/database.dart';
import '../security/secret_encryption_service.dart';
import 'like_query.dart';

/// Repository for managing host entities.
class HostRepository {
  /// Creates a new [HostRepository].
  HostRepository(this._db, this._secretEncryptionService);

  final AppDatabase _db;
  final SecretEncryptionService _secretEncryptionService;

  static const _maxDecryptCacheEntries = 512;

  // Ciphertext-keyed cache so repeated watchAll emissions only pay the
  // AES-GCM cost for rows whose encrypted field actually changed.
  // Keyed by the full ENCv1:… envelope string; value is the decrypted
  // plaintext. Entries are bounded and cleared on auth lock / writes.
  final _decryptCache = <String, String>{};
  final _undecryptablePasswordHostIds = <int>{};

  /// Clears cached decrypted secret plaintexts.
  void clearDecryptionCache() {
    _decryptCache.clear();
    _undecryptablePasswordHostIds.clear();
  }

  /// Number of cached decrypted secret plaintexts.
  @visibleForTesting
  int get debugDecryptionCacheSize => _decryptCache.length;

  /// Get all hosts.
  Future<List<Host>> getAll() => _orderedHostsQuery().get().then(_decryptHosts);

  /// Watch all hosts.
  Stream<List<Host>> watchAll() =>
      _orderedHostsQuery().watch().asyncMap(_decryptHosts);

  /// Get hosts by group.
  Future<List<Host>> getByGroup(int? groupId) =>
      (_orderedHostsQuery()..where((h) => h.groupId.equalsNullable(groupId)))
          .get()
          .then(_decryptHosts);

  /// Watch hosts by group.
  Stream<List<Host>> watchByGroup(int? groupId) =>
      (_orderedHostsQuery()..where((h) => h.groupId.equalsNullable(groupId)))
          .watch()
          .asyncMap(_decryptHosts);

  /// Get favorite hosts.
  Future<List<Host>> getFavorites() =>
      (_orderedHostsQuery()..where((h) => h.isFavorite.equals(true)))
          .get()
          .then(_decryptHosts);

  /// Watch favorite hosts.
  Stream<List<Host>> watchFavorites() =>
      (_orderedHostsQuery()..where((h) => h.isFavorite.equals(true)))
          .watch()
          .asyncMap(_decryptHosts);

  /// Get a host by ID.
  Future<Host?> getById(int id) async {
    final host = await (_db.select(
      _db.hosts,
    )..where((h) => h.id.equals(id))).getSingleOrNull();
    if (host == null) {
      return null;
    }
    return _decryptHost(host);
  }

  /// Watch a single host by ID.
  Stream<Host?> watchById(int id) =>
      (_db.select(
        _db.hosts,
      )..where((h) => h.id.equals(id))).watchSingleOrNull().asyncMap(
        (host) => host == null ? Future.value() : _decryptHost(host),
      );

  /// Resolves this host's collision-free custom or generated proxy name.
  Future<String> resolveProxyName({
    required int hostId,
    required String label,
    String? customName,
  }) async {
    final rows =
        await (_db.selectOnly(_db.hosts)..addColumns([
              _db.hosts.id,
              _db.hosts.label,
              _db.hosts.portProxyName,
            ]))
            .get();
    final normalizedCustomName = normalizeOptionalStoredPortProxyName(
      customName,
    );
    if (normalizedCustomName != null &&
        isReservedSavedForwardProxyName(normalizedCustomName)) {
      throw PortProxyNameConflictException(normalizedCustomName);
    }
    final customNamesById = <int, String>{};
    final hosts = [
      for (final row in rows)
        (
          id: row.read(_db.hosts.id)!,
          label: row.read(_db.hosts.id) == hostId
              ? label
              : row.read(_db.hosts.label) ?? '',
        ),
    ];
    if (!hosts.any((host) => host.id == hostId)) {
      hosts.add((id: hostId, label: label));
    }
    for (final row in rows) {
      final id = row.read(_db.hosts.id)!;
      final name = normalizeOptionalStoredPortProxyName(
        id == hostId ? customName : row.read(_db.hosts.portProxyName),
      );
      if (name != null) {
        customNamesById[id] = name;
      }
    }
    if (normalizedCustomName != null) {
      customNamesById[hostId] = normalizedCustomName;
      if (customNamesById.entries.any(
        (entry) => entry.key != hostId && entry.value == normalizedCustomName,
      )) {
        throw PortProxyNameConflictException(normalizedCustomName);
      }
    }

    final generatedHosts = hosts
        .where((host) => !customNamesById.containsKey(host.id))
        .toList(growable: false);
    final existingGeneratedNames = resolveGeneratedPortProxyNames(
      generatedHosts,
      reservedNames: normalizedCustomName == null
          ? customNamesById.values
          : customNamesById.entries
                .where((entry) => entry.key != hostId)
                .map((entry) => entry.value),
    );
    if (normalizedCustomName != null) {
      if (existingGeneratedNames.values.contains(normalizedCustomName)) {
        throw PortProxyNameConflictException(normalizedCustomName);
      }
      return normalizedCustomName;
    }
    return existingGeneratedNames[hostId] ?? generatedPortProxySlug(label);
  }

  /// Search hosts by label, hostname, or tags.
  ///
  /// The query is treated as a literal string: `%` and `_` are matched
  /// exactly rather than acting as SQL LIKE wildcards.
  Future<List<Host>> search(String query) {
    final escaped = escapeSqlLikeQuery(query);
    return (_orderedHostsQuery()..where(
          (h) =>
              h.label.like('%$escaped%', escapeChar: sqlLikeEscapeCharacter) |
              h.hostname.like(
                '%$escaped%',
                escapeChar: sqlLikeEscapeCharacter,
              ) |
              h.tags.like('%$escaped%', escapeChar: sqlLikeEscapeCharacter),
        ))
        .get()
        .then(_decryptHosts);
  }

  /// Insert a new host.
  Future<int> insert(HostsCompanion host) async {
    if (host.portProxyName.present && host.portProxyName.value != null) {
      await validateProxyName(
        hostId: -1,
        label: host.label.value,
        customName: host.portProxyName.value,
      );
    }
    final encryptedHost = await _encryptHostCompanion(
      host.copyWith(
        sortOrder: host.sortOrder.present
            ? host.sortOrder
            : Value(await _nextSortOrder()),
      ),
    );
    return _db.into(_db.hosts).insert(encryptedHost);
  }

  /// Validates a custom proxy name against every saved alias.
  Future<void> validateProxyName({
    required int hostId,
    required String label,
    String? customName,
  }) async {
    if (normalizeOptionalStoredPortProxyName(customName) == null) {
      return;
    }
    await resolveProxyName(
      hostId: hostId,
      label: label,
      customName: customName,
    );
  }

  /// Reorders all hosts to match [orderedIds].
  Future<void> reorderByIds(List<int> orderedIds) async {
    if (orderedIds.isEmpty) {
      return;
    }

    await _db.transaction(() async {
      for (var index = 0; index < orderedIds.length; index += 1) {
        await (_db.update(_db.hosts)
              ..where((h) => h.id.equals(orderedIds[index])))
            .write(HostsCompanion(sortOrder: Value(index)));
      }
    });
  }

  /// Duplicate an existing host and its port forwards.
  Future<int> duplicate(Host host) => _db.transaction(() async {
    final duplicateHostId = await insert(
      host
          .toCompanion(false)
          .copyWith(
            id: const Value.absent(),
            label: Value('${host.label} (copy)'),
            createdAt: const Value.absent(),
            updatedAt: const Value.absent(),
            lastConnectedAt: const Value(null),
            portProxyName: const Value(null),
            sortOrder: const Value.absent(),
          ),
    );

    final portForwards = await (_db.select(
      _db.portForwards,
    )..where((portForward) => portForward.hostId.equals(host.id))).get();

    for (final portForward in portForwards) {
      await _db
          .into(_db.portForwards)
          .insert(
            portForward
                .toCompanion(false)
                .copyWith(
                  id: const Value.absent(),
                  hostId: Value(duplicateHostId),
                  createdAt: const Value.absent(),
                ),
          );
    }

    return duplicateHostId;
  });

  /// Update an existing host.
  Future<bool> update(Host host) async {
    final previousStoredPassword = await _storedPasswordForHost(host.id);
    final preservesUnreadablePassword =
        _undecryptablePasswordHostIds.contains(host.id) &&
        (host.password == null || host.password!.isEmpty) &&
        previousStoredPassword != null;
    final encryptedPassword = preservesUnreadablePassword
        ? previousStoredPassword
        : await _secretEncryptionService.encryptNullable(host.password);
    final updated = await _db
        .update(_db.hosts)
        .replace(host.copyWith(password: Value(encryptedPassword)));
    if (updated && !preservesUnreadablePassword) {
      _undecryptablePasswordHostIds.remove(host.id);
      _evictDecrypted(previousStoredPassword);
      _rememberEncryptedPlaintext(encryptedPassword, host.password);
    }
    return updated;
  }

  /// Delete a host.
  Future<int> delete(int id) async {
    final host = await (_db.select(
      _db.hosts,
    )..where((h) => h.id.equals(id))).getSingleOrNull();
    if (host == null) {
      return 0;
    }
    final previousStoredPassword = host.password;
    final deleted = await _db.transaction(() async {
      await (_db.delete(
        _db.portForwards,
      )..where((portForward) => portForward.hostId.equals(id))).go();
      return (_db.delete(_db.hosts)..where((h) => h.id.equals(id))).go();
    });
    if (deleted > 0) {
      _evictDecrypted(previousStoredPassword);
      _undecryptablePasswordHostIds.remove(id);
    }
    return deleted;
  }

  /// Toggle favorite status.
  Future<bool> toggleFavorite(int id) async {
    final updated = await (_db.update(_db.hosts)..where((h) => h.id.equals(id)))
        .write(HostsCompanion.custom(isFavorite: _db.hosts.isFavorite.not()));
    return updated > 0;
  }

  /// Applies a partial column update to a single host.
  ///
  /// Unlike [update], this never rewrites columns the caller did not set, so a
  /// stale in-memory [Host] snapshot cannot clobber fields changed elsewhere.
  /// The `password` column is always left untouched here; use [update] for
  /// credential changes so the secret is encrypted and cached correctly.
  Future<bool> updateFields(int id, HostsCompanion changes) async {
    final updatedRows =
        await (_db.update(_db.hosts)..where((h) => h.id.equals(id))).write(
          changes.copyWith(
            id: const Value.absent(),
            password: const Value.absent(),
          ),
        );
    return updatedRows > 0;
  }

  /// Enable or disable automatic forwarding of newly opened remote ports.
  Future<bool> setAutoForwardPorts(int id, {required bool enabled}) =>
      updateFields(id, HostsCompanion(autoForwardPorts: Value(enabled)));

  /// Update last connected timestamp.
  Future<bool> updateLastConnected(int id) =>
      updateFields(id, HostsCompanion(lastConnectedAt: Value(DateTime.now())));

  Future<List<Host>> _decryptHosts(List<Host> hosts) =>
      Future.wait(hosts.map(_decryptHost));

  Future<Host> _decryptHost(Host host) async {
    final storedPassword = host.password;
    if (storedPassword == null || storedPassword.isEmpty) {
      return host;
    }

    final decryptedPassword = await _cachedDecryptOrMigratePassword(
      host.id,
      storedPassword,
    );
    return host.copyWith(password: Value(decryptedPassword));
  }

  /// Returns the decrypted form of [ciphertext], using [_decryptCache] to
  /// avoid redundant AES-GCM operations across stream emissions.
  Future<String?> _cachedDecrypt(String ciphertext) async {
    final hit = _decryptCache.remove(ciphertext);
    if (hit != null) {
      _decryptCache[ciphertext] = hit;
      return hit;
    }

    final plaintext = await _secretEncryptionService.decryptNullable(
      ciphertext,
    );
    if (plaintext != null && plaintext.isNotEmpty) {
      _rememberDecrypted(ciphertext, plaintext);
    }
    return plaintext;
  }

  Future<String?> _cachedDecryptOrMigratePassword(
    int hostId,
    String storedPassword,
  ) async {
    if (_secretEncryptionService.isValidEncryptedEnvelope(storedPassword)) {
      try {
        final decryptedPassword = await _cachedDecrypt(storedPassword);
        _undecryptablePasswordHostIds.remove(hostId);
        return decryptedPassword;
      } on FormatException catch (error) {
        // Keep the host usable without allowing metadata writes to erase the
        // ciphertext if secure storage loses its encryption key.
        _undecryptablePasswordHostIds.add(hostId);
        DiagnosticsLogService.instance.warning(
          'host.secrets',
          'password_decryption_failed',
          fields: {'hostId': hostId, 'errorType': error.runtimeType},
        );
        return null;
      }
    }

    _undecryptablePasswordHostIds.remove(hostId);
    final encryptedPassword = await _secretEncryptionService.encryptNullable(
      storedPassword,
    );
    if (encryptedPassword != null && encryptedPassword != storedPassword) {
      await (_db.update(_db.hosts)..where(
            (h) => h.id.equals(hostId) & h.password.equals(storedPassword),
          ))
          .write(HostsCompanion(password: Value(encryptedPassword)));
      _rememberDecrypted(encryptedPassword, storedPassword);
    }
    return storedPassword;
  }

  Future<String?> _storedPasswordForHost(int id) async {
    final row = await (_db.select(
      _db.hosts,
    )..where((h) => h.id.equals(id))).getSingleOrNull();
    return row?.password;
  }

  void _rememberEncryptedPlaintext(String? ciphertext, String? plaintext) {
    if (ciphertext == null ||
        ciphertext.isEmpty ||
        plaintext == null ||
        plaintext.isEmpty ||
        _secretEncryptionService.isEncryptedValue(plaintext)) {
      return;
    }
    _rememberDecrypted(ciphertext, plaintext);
  }

  void _rememberDecrypted(String ciphertext, String plaintext) {
    _decryptCache.remove(ciphertext);
    _decryptCache[ciphertext] = plaintext;
    while (_decryptCache.length > _maxDecryptCacheEntries) {
      _decryptCache.remove(_decryptCache.keys.first);
    }
  }

  void _evictDecrypted(String? ciphertext) {
    if (ciphertext == null || ciphertext.isEmpty) {
      return;
    }
    _decryptCache.remove(ciphertext);
  }

  Future<HostsCompanion> _encryptHostCompanion(HostsCompanion host) async {
    if (!host.password.present || host.password.value == null) {
      return host;
    }
    final encryptedPassword = await _secretEncryptionService.encryptNullable(
      host.password.value,
    );
    return host.copyWith(password: Value(encryptedPassword));
  }

  SimpleSelectStatement<$HostsTable, Host> _orderedHostsQuery() =>
      _db.select(_db.hosts)..orderBy([
        (h) => OrderingTerm.asc(h.sortOrder),
        (h) => OrderingTerm.asc(h.id),
      ]);

  Future<int> _nextSortOrder() async {
    final expression = _db.hosts.sortOrder.max();
    final row = await (_db.selectOnly(
      _db.hosts,
    )..addColumns([expression])).getSingleOrNull();
    return (row?.read(expression) ?? -1) + 1;
  }
}

/// Provider for [HostRepository].
final hostRepositoryProvider = Provider<HostRepository>((ref) {
  final repository = HostRepository(
    ref.watch(databaseProvider),
    ref.watch(secretEncryptionServiceProvider),
  );
  ref.listen<AuthState>(authStateProvider, (_, next) {
    if (next == AuthState.locked) {
      repository.clearDecryptionCache();
    }
  });
  return repository;
});
