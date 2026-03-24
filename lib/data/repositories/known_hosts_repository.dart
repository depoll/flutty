import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database.dart';

/// Repository for the persisted SSH known-hosts trust store.
class KnownHostsRepository {
  /// Creates a [KnownHostsRepository].
  KnownHostsRepository(this._db);

  final AppDatabase _db;

  /// Returns the trusted host entry for [hostname]:[port], if any.
  Future<KnownHost?> getByHost(String hostname, int port) =>
      (_db.select(_db.knownHosts)..where(
            (knownHost) =>
                knownHost.hostname.equals(hostname) &
                knownHost.port.equals(port),
          ))
          .getSingleOrNull();

  /// Inserts or replaces the trusted record for [hostname]:[port].
  Future<void> upsertTrustedHost({
    required String hostname,
    required int port,
    required String keyType,
    required String fingerprint,
    required String encodedHostKey,
    required bool resetFirstSeen,
  }) async {
    final now = DateTime.now();
    final unixSeconds = now.millisecondsSinceEpoch ~/ 1000;
    final shouldResetFirstSeen = resetFirstSeen ? 1 : 0;
    await _db.customStatement(
      '''
      INSERT INTO known_hosts (
        hostname,
        port,
        key_type,
        fingerprint,
        host_key,
        first_seen,
        last_seen
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(hostname, port) DO UPDATE SET
        key_type = excluded.key_type,
        fingerprint = excluded.fingerprint,
        host_key = excluded.host_key,
        first_seen = CASE
          WHEN ? = 1 THEN excluded.first_seen
          ELSE known_hosts.first_seen
        END,
        last_seen = excluded.last_seen
      ''',
      <Object?>[
        hostname,
        port,
        keyType,
        fingerprint,
        encodedHostKey,
        unixSeconds,
        unixSeconds,
        shouldResetFirstSeen,
      ],
    );
  }

  /// Updates [lastSeen] after a trusted host key authenticates successfully.
  Future<void> markTrustedHostSeen({
    required String hostname,
    required int port,
    required String keyType,
    required String fingerprint,
    required String encodedHostKey,
  }) async {
    final existing = await getByHost(hostname, port);
    if (existing == null) {
      throw StateError(
        'Cannot update an unseen trusted host for $hostname:$port.',
      );
    }

    await (_db.update(
      _db.knownHosts,
    )..where((knownHost) => knownHost.id.equals(existing.id))).write(
      KnownHostsCompanion(
        keyType: Value(keyType),
        fingerprint: Value(fingerprint),
        hostKey: Value(encodedHostKey),
        lastSeen: Value(DateTime.now()),
      ),
    );
  }
}

/// Provider for [KnownHostsRepository].
final knownHostsRepositoryProvider = Provider<KnownHostsRepository>(
  (ref) => KnownHostsRepository(ref.watch(databaseProvider)),
);
