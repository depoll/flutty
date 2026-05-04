import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/services/auth_service.dart';
import '../database/database.dart';
import '../security/secret_encryption_service.dart';

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

  /// Clears cached decrypted secret plaintexts.
  void clearDecryptionCache() {
    _decryptCache.clear();
  }

  /// Number of cached decrypted secret plaintexts.
  @visibleForTesting
  int get debugDecryptionCacheSize => _decryptCache.length;

  /// Get all hosts.
  Future<List<Host>> getAll() async {
    final hosts = await _orderedHostsQuery().get();
    return Future.wait(hosts.map(_decryptHost));
  }

  /// Watch all hosts.
  Stream<List<Host>> watchAll() =>
      _orderedHostsQuery().watch().asyncMap(_decryptHosts);

  /// Get hosts by group.
  Future<List<Host>> getByGroup(int? groupId) {
    if (groupId == null) {
      return (_orderedHostsQuery()..where((h) => h.groupId.isNull()))
          .get()
          .then(_decryptHosts);
    }
    return (_orderedHostsQuery()..where((h) => h.groupId.equals(groupId)))
        .get()
        .then(_decryptHosts);
  }

  /// Watch hosts by group.
  Stream<List<Host>> watchByGroup(int? groupId) {
    if (groupId == null) {
      return (_orderedHostsQuery()..where((h) => h.groupId.isNull()))
          .watch()
          .asyncMap(_decryptHosts);
    }
    return (_orderedHostsQuery()..where((h) => h.groupId.equals(groupId)))
        .watch()
        .asyncMap(_decryptHosts);
  }

  /// Get favorite hosts.
  Future<List<Host>> getFavorites() =>
      (_db.select(_db.hosts)
            ..where((h) => h.isFavorite.equals(true))
            ..orderBy([
              (h) => OrderingTerm.asc(h.sortOrder),
              (h) => OrderingTerm.asc(h.id),
            ]))
          .get()
          .then(_decryptHosts);

  /// Watch favorite hosts.
  Stream<List<Host>> watchFavorites() =>
      (_db.select(_db.hosts)
            ..where((h) => h.isFavorite.equals(true))
            ..orderBy([
              (h) => OrderingTerm.asc(h.sortOrder),
              (h) => OrderingTerm.asc(h.id),
            ]))
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

  /// Search hosts by label, hostname, or tags.
  ///
  /// The query is treated as a literal string: `%` and `_` are matched
  /// exactly rather than acting as SQL LIKE wildcards.
  Future<List<Host>> search(String query) {
    final escaped = _escapeLike(query);
    return (_db.select(_db.hosts)
          ..where(
            (h) =>
                h.label.like('%$escaped%', escapeChar: r'\') |
                h.hostname.like('%$escaped%', escapeChar: r'\') |
                h.tags.like('%$escaped%', escapeChar: r'\'),
          )
          ..orderBy([
            (h) => OrderingTerm.asc(h.sortOrder),
            (h) => OrderingTerm.asc(h.id),
          ]))
        .get()
        .then(_decryptHosts);
  }

  /// Escapes SQLite LIKE metacharacters so that `%`, `_`, and `\` in the
  /// [query] are matched literally rather than as pattern characters.
  static String _escapeLike(String query) => query
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Insert a new host.
  Future<int> insert(HostsCompanion host) async {
    final encryptedHost = await _encryptHostCompanion(
      host.copyWith(
        sortOrder: host.sortOrder.present
            ? host.sortOrder
            : Value(await _nextSortOrder()),
      ),
    );
    return _db.into(_db.hosts).insert(encryptedHost);
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
      HostsCompanion.insert(
        label: '${host.label} (copy)',
        hostname: host.hostname,
        port: Value(host.port),
        username: host.username,
        password: Value(host.password),
        keyId: Value(host.keyId),
        groupId: Value(host.groupId),
        jumpHostId: Value(host.jumpHostId),
        isFavorite: Value(host.isFavorite),
        color: Value(host.color),
        notes: Value(host.notes),
        tags: Value(host.tags),
        terminalThemeLightId: Value(host.terminalThemeLightId),
        terminalThemeDarkId: Value(host.terminalThemeDarkId),
        terminalFontFamily: Value(host.terminalFontFamily),
        autoConnectCommand: Value(host.autoConnectCommand),
        autoConnectSnippetId: Value(host.autoConnectSnippetId),
        autoConnectRequiresConfirmation: Value(
          host.autoConnectRequiresConfirmation,
        ),
      ),
    );

    final portForwards = await (_db.select(
      _db.portForwards,
    )..where((portForward) => portForward.hostId.equals(host.id))).get();

    for (final portForward in portForwards) {
      await _db
          .into(_db.portForwards)
          .insert(
            PortForwardsCompanion.insert(
              name: portForward.name,
              hostId: duplicateHostId,
              forwardType: portForward.forwardType,
              localHost: Value(portForward.localHost),
              localPort: portForward.localPort,
              remoteHost: portForward.remoteHost,
              remotePort: portForward.remotePort,
              autoStart: Value(portForward.autoStart),
            ),
          );
    }

    return duplicateHostId;
  });

  /// Update an existing host.
  Future<bool> update(Host host) async {
    final previousStoredPassword = await _storedPasswordForHost(host.id);
    final encryptedPassword = await _secretEncryptionService.encryptNullable(
      host.password,
    );
    final updated = await _db
        .update(_db.hosts)
        .replace(host.copyWith(password: Value(encryptedPassword)));
    if (updated) {
      _evictDecrypted(previousStoredPassword);
      _rememberEncryptedPlaintext(encryptedPassword, host.password);
    }
    return updated;
  }

  /// Delete a host.
  Future<int> delete(int id) async {
    final previousStoredPassword = await _storedPasswordForHost(id);
    final deleted = await (_db.delete(
      _db.hosts,
    )..where((h) => h.id.equals(id))).go();
    if (deleted > 0) {
      _evictDecrypted(previousStoredPassword);
    }
    return deleted;
  }

  /// Toggle favorite status.
  Future<bool> toggleFavorite(int id) async {
    final host = await getById(id);
    if (host == null) return false;
    return update(host.copyWith(isFavorite: !host.isFavorite));
  }

  /// Update last connected timestamp.
  Future<bool> updateLastConnected(int id) async {
    final host = await getById(id);
    if (host == null) return false;
    return update(host.copyWith(lastConnectedAt: Value(DateTime.now())));
  }

  Future<List<Host>> _decryptHosts(List<Host> hosts) =>
      Future.wait(hosts.map(_decryptHost));

  Future<Host> _decryptHost(Host host) async {
    final storedPassword = host.password;
    if (storedPassword == null || storedPassword.isEmpty) {
      return host;
    }

    final decryptedPassword = await _cachedDecrypt(storedPassword);
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
