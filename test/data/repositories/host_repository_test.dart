// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';

void main() {
  late AppDatabase db;
  late HostRepository repository;
  late SecretEncryptionService encryptionService;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    encryptionService = SecretEncryptionService.forTesting();
    repository = HostRepository(db, encryptionService);
  });

  tearDown(() async {
    await db.close();
  });

  group('HostRepository', () {
    test('getAll returns empty list initially', () async {
      final hosts = await repository.getAll();
      expect(hosts, isEmpty);
    });

    test('insert creates a new host', () async {
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      expect(id, greaterThan(0));

      final hosts = await repository.getAll();
      expect(hosts, hasLength(1));
      expect(hosts.first.label, 'Test Server');
      expect(hosts.first.hostname, '192.168.1.1');
      expect(hosts.first.username, 'admin');
      expect(hosts.first.sortOrder, 0);
    });

    test('insert appends hosts by sort order', () async {
      await repository.insert(
        HostsCompanion.insert(
          label: 'First',
          hostname: 'first.example.com',
          username: 'root',
        ),
      );
      await repository.insert(
        HostsCompanion.insert(
          label: 'Second',
          hostname: 'second.example.com',
          username: 'root',
        ),
      );

      final hosts = await repository.getAll();
      expect(hosts.map((host) => host.sortOrder), [0, 1]);
      expect(hosts.map((host) => host.label), ['First', 'Second']);
    });

    test('reorderByIds persists host order', () async {
      final firstId = await repository.insert(
        HostsCompanion.insert(
          label: 'First',
          hostname: 'first.example.com',
          username: 'root',
        ),
      );
      final secondId = await repository.insert(
        HostsCompanion.insert(
          label: 'Second',
          hostname: 'second.example.com',
          username: 'root',
        ),
      );
      final thirdId = await repository.insert(
        HostsCompanion.insert(
          label: 'Third',
          hostname: 'third.example.com',
          username: 'root',
        ),
      );

      await repository.reorderByIds([thirdId, firstId, secondId]);

      final hosts = await repository.getAll();
      expect(hosts.map((host) => host.label), ['Third', 'First', 'Second']);
      expect(hosts.map((host) => host.sortOrder), [0, 1, 2]);
    });

    test('insert encrypts password at rest', () async {
      const plaintextPassword = 'super-secret';
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Secure Host',
          hostname: '192.168.1.10',
          username: 'admin',
          password: const Value(plaintextPassword),
        ),
      );

      final storedHost = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingle();
      expect(storedHost.password, isNot(plaintextPassword));
      expect(storedHost.password, startsWith('ENCv1:'));

      final host = await repository.getById(id);
      expect(host!.password, plaintextPassword);
    });

    test('insert stores auto-connect command fields', () async {
      final snippetId = await db
          .into(db.snippets)
          .insert(
            SnippetsCompanion.insert(
              name: 'Attach tmux',
              command: 'tmux attach',
            ),
          );

      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
          autoConnectCommand: const Value('tmux attach'),
          autoConnectSnippetId: Value(snippetId),
          autoConnectRequiresConfirmation: const Value(true),
        ),
      );

      final host = await repository.getById(id);
      expect(host, isNotNull);
      expect(host!.autoConnectCommand, 'tmux attach');
      expect(host.autoConnectSnippetId, snippetId);
      expect(host.autoConnectRequiresConfirmation, isTrue);
    });

    test('duplicate copies all host fields and port forwards', () async {
      final keyId = await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Deploy Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest',
              privateKey: 'PRIVATE KEY',
            ),
          );
      final groupId = await db
          .into(db.groups)
          .insert(GroupsCompanion.insert(name: 'Production'));
      final snippetId = await db
          .into(db.snippets)
          .insert(
            SnippetsCompanion.insert(
              name: 'Attach tmux',
              command: 'tmux attach',
            ),
          );
      final jumpHostId = await repository.insert(
        HostsCompanion.insert(
          label: 'Jump Host',
          hostname: 'jump.example.com',
          username: 'jump',
        ),
      );

      final sourceHostId = await repository.insert(
        HostsCompanion.insert(
          label: 'Primary Server',
          hostname: 'prod.example.com',
          port: const Value(2200),
          username: 'deploy',
          password: const Value('s3cr3t'),
          keyId: Value(keyId),
          groupId: Value(groupId),
          jumpHostId: Value(jumpHostId),
          isFavorite: const Value(true),
          color: const Value('#112233'),
          notes: const Value('Has extra metadata'),
          tags: const Value('prod,critical'),
          createdAt: Value(DateTime(2020, 1, 2, 3, 4, 5)),
          updatedAt: Value(DateTime(2021, 2, 3, 4, 5, 6)),
          lastConnectedAt: Value(DateTime(2022, 3, 4, 5, 6, 7)),
          terminalThemeLightId: const Value('solarized-light'),
          terminalThemeDarkId: const Value('solarized-dark'),
          terminalFontFamily: const Value('Fira Code'),
          autoConnectCommand: const Value('tmux attach'),
          autoConnectSnippetId: Value(snippetId),
          autoConnectRequiresConfirmation: const Value(true),
        ),
      );

      await db
          .into(db.portForwards)
          .insert(
            PortForwardsCompanion.insert(
              hostId: sourceHostId,
              name: 'Database Tunnel',
              forwardType: 'local',
              localHost: const Value('0.0.0.0'),
              localPort: 5432,
              remoteHost: 'db.internal',
              remotePort: 5432,
              autoStart: const Value(true),
            ),
          );
      await db
          .into(db.portForwards)
          .insert(
            PortForwardsCompanion.insert(
              hostId: sourceHostId,
              name: 'Redis Tunnel',
              forwardType: 'remote',
              localHost: const Value('127.0.0.1'),
              localPort: 6379,
              remoteHost: 'redis.internal',
              remotePort: 6379,
              autoStart: const Value(false),
            ),
          );

      final sourceHost = await repository.getById(sourceHostId);
      final duplicateHostId = await repository.duplicate(sourceHost!);

      expect(duplicateHostId, isNot(sourceHostId));

      final duplicateHost = await repository.getById(duplicateHostId);

      expect(duplicateHost, isNotNull);
      expect(duplicateHost!.label, 'Primary Server (copy)');
      expect(duplicateHost.hostname, sourceHost.hostname);
      expect(duplicateHost.port, sourceHost.port);
      expect(duplicateHost.username, sourceHost.username);
      expect(duplicateHost.password, sourceHost.password);
      expect(duplicateHost.keyId, sourceHost.keyId);
      expect(duplicateHost.groupId, sourceHost.groupId);
      expect(duplicateHost.jumpHostId, sourceHost.jumpHostId);
      expect(duplicateHost.isFavorite, sourceHost.isFavorite);
      expect(duplicateHost.color, sourceHost.color);
      expect(duplicateHost.notes, sourceHost.notes);
      expect(duplicateHost.tags, sourceHost.tags);
      expect(
        duplicateHost.terminalThemeLightId,
        sourceHost.terminalThemeLightId,
      );
      expect(duplicateHost.terminalThemeDarkId, sourceHost.terminalThemeDarkId);
      expect(duplicateHost.terminalFontFamily, sourceHost.terminalFontFamily);
      expect(duplicateHost.autoConnectCommand, sourceHost.autoConnectCommand);
      expect(
        duplicateHost.autoConnectSnippetId,
        sourceHost.autoConnectSnippetId,
      );
      expect(
        duplicateHost.autoConnectRequiresConfirmation,
        sourceHost.autoConnectRequiresConfirmation,
      );
      expect(duplicateHost.lastConnectedAt, isNull);
      expect(duplicateHost.createdAt, isNot(sourceHost.createdAt));
      expect(duplicateHost.updatedAt, isNot(sourceHost.updatedAt));

      final duplicatePortForwards =
          await (db.select(db.portForwards)..where(
                (portForward) => portForward.hostId.equals(duplicateHostId),
              ))
              .get();

      expect(duplicatePortForwards, hasLength(2));
      expect(
        duplicatePortForwards.map((portForward) => portForward.name),
        unorderedEquals(['Database Tunnel', 'Redis Tunnel']),
      );

      final databaseTunnel = duplicatePortForwards.singleWhere(
        (portForward) => portForward.name == 'Database Tunnel',
      );
      expect(databaseTunnel.hostId, duplicateHostId);
      expect(databaseTunnel.forwardType, 'local');
      expect(databaseTunnel.localHost, '0.0.0.0');
      expect(databaseTunnel.localPort, 5432);
      expect(databaseTunnel.remoteHost, 'db.internal');
      expect(databaseTunnel.remotePort, 5432);
      expect(databaseTunnel.autoStart, isTrue);

      final redisTunnel = duplicatePortForwards.singleWhere(
        (portForward) => portForward.name == 'Redis Tunnel',
      );
      expect(redisTunnel.hostId, duplicateHostId);
      expect(redisTunnel.forwardType, 'remote');
      expect(redisTunnel.localHost, '127.0.0.1');
      expect(redisTunnel.localPort, 6379);
      expect(redisTunnel.remoteHost, 'redis.internal');
      expect(redisTunnel.remotePort, 6379);
      expect(redisTunnel.autoStart, isFalse);
    });

    test('getById returns host when exists', () async {
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      final host = await repository.getById(id);

      expect(host, isNotNull);
      expect(host!.id, id);
      expect(host.label, 'Test Server');
    });

    test('getById returns null when not exists', () async {
      final host = await repository.getById(999);
      expect(host, isNull);
    });

    test('update modifies existing host', () async {
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      final host = await repository.getById(id);
      final success = await repository.update(
        host!.copyWith(label: 'Updated Server', port: 2222),
      );

      expect(success, isTrue);

      final updated = await repository.getById(id);
      expect(updated!.label, 'Updated Server');
      expect(updated.port, 2222);
    });

    test('update persists auto-connect command changes', () async {
      final snippetId = await db
          .into(db.snippets)
          .insert(
            SnippetsCompanion.insert(
              name: 'Attach tmux',
              command: 'tmux attach',
            ),
          );
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      final host = await repository.getById(id);
      final success = await repository.update(
        host!.copyWith(
          autoConnectCommand: const Value('tmux new -As MonkeySSH'),
          autoConnectSnippetId: Value(snippetId),
        ),
      );

      expect(success, isTrue);

      final updated = await repository.getById(id);
      expect(updated!.autoConnectCommand, 'tmux new -As MonkeySSH');
      expect(updated.autoConnectSnippetId, snippetId);
    });

    test('update does not double-encrypt a pre-encrypted password', () async {
      const plaintextPassword = 'pre-encrypted-pass';
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Secure Host',
          hostname: '10.0.0.1',
          username: 'admin',
          password: const Value(plaintextPassword),
        ),
      );

      // Read the raw stored row (password is already encrypted by insert).
      final rawHost = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingle();
      expect(rawHost.password, startsWith('ENCv1:'));
      final storedEncryptedPassword = rawHost.password!;

      // Call update with the already-encrypted state (skipping the normal
      // getById decryption path) to prove no double-encryption occurs.
      await repository.update(rawHost.copyWith(label: 'Updated Host'));

      final afterUpdate = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingle();
      expect(afterUpdate.password, startsWith('ENCv1:'));
      // The stored value must not be a double-wrapped ENCv1 envelope.
      expect(afterUpdate.password, isNot(contains('ENCv1:ENCv1:')));
      // The stored value should be identical since the service skips
      // re-encrypting an already valid envelope.
      expect(afterUpdate.password, storedEncryptedPassword);

      // Round-trip through the repository should still yield original plaintext.
      final decrypted = await repository.getById(id);
      expect(decrypted!.password, plaintextPassword);
    });

    test('toggleFavorite does not double-encrypt the password', () async {
      const plaintextPassword = 'fav-password';
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Host',
          hostname: '10.0.0.2',
          username: 'admin',
          password: const Value(plaintextPassword),
        ),
      );

      // Two toggles to exercise the full update cycle twice.
      await repository.toggleFavorite(id);
      await repository.toggleFavorite(id);

      final rawHost = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingle();
      expect(rawHost.password, startsWith('ENCv1:'));
      expect(rawHost.password, isNot(contains('ENCv1:ENCv1:')));

      final decrypted = await repository.getById(id);
      expect(decrypted!.password, plaintextPassword);
    });

    test('updateLastConnected does not double-encrypt the password', () async {
      const plaintextPassword = 'last-connect-pass';
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Host',
          hostname: '10.0.0.3',
          username: 'admin',
          password: const Value(plaintextPassword),
        ),
      );

      await repository.updateLastConnected(id);
      await repository.updateLastConnected(id);

      final rawHost = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingle();
      expect(rawHost.password, startsWith('ENCv1:'));
      expect(rawHost.password, isNot(contains('ENCv1:ENCv1:')));

      final decrypted = await repository.getById(id);
      expect(decrypted!.password, plaintextPassword);
    });

    test('duplicate does not double-encrypt the password', () async {
      const plaintextPassword = 'dup-password';
      final sourceId = await repository.insert(
        HostsCompanion.insert(
          label: 'Source Host',
          hostname: '10.0.0.4',
          username: 'admin',
          password: const Value(plaintextPassword),
        ),
      );

      final sourceHost = await repository.getById(sourceId);
      final dupId = await repository.duplicate(sourceHost!);

      final rawDup = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(dupId))).getSingle();
      expect(rawDup.password, startsWith('ENCv1:'));
      expect(rawDup.password, isNot(contains('ENCv1:ENCv1:')));

      final decryptedDup = await repository.getById(dupId);
      expect(decryptedDup!.password, plaintextPassword);
    });

    test('delete removes host', () async {
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      final deleted = await repository.delete(id);
      expect(deleted, 1);

      final host = await repository.getById(id);
      expect(host, isNull);
    });

    test('delete returns 0 when host not exists', () async {
      final deleted = await repository.delete(999);
      expect(deleted, 0);
    });

    test('toggleFavorite toggles favorite status', () async {
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      var host = await repository.getById(id);
      expect(host!.isFavorite, isFalse);

      await repository.toggleFavorite(id);

      host = await repository.getById(id);
      expect(host!.isFavorite, isTrue);

      await repository.toggleFavorite(id);

      host = await repository.getById(id);
      expect(host!.isFavorite, isFalse);
    });

    test('toggleFavorite returns false when host not exists', () async {
      final result = await repository.toggleFavorite(999);
      expect(result, isFalse);
    });

    test('getFavorites returns only favorite hosts', () async {
      await repository.insert(
        HostsCompanion.insert(
          label: 'Server 1',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );
      final id2 = await repository.insert(
        HostsCompanion.insert(
          label: 'Server 2',
          hostname: '192.168.1.2',
          username: 'admin',
        ),
      );

      await repository.toggleFavorite(id2);

      final favorites = await repository.getFavorites();
      expect(favorites, hasLength(1));
      expect(favorites.first.label, 'Server 2');
    });

    test('search finds hosts by label', () async {
      await repository.insert(
        HostsCompanion.insert(
          label: 'Production Server',
          hostname: '10.0.0.1',
          username: 'admin',
        ),
      );
      await repository.insert(
        HostsCompanion.insert(
          label: 'Dev Server',
          hostname: '192.168.1.1',
          username: 'dev',
        ),
      );

      final results = await repository.search('Production');
      expect(results, hasLength(1));
      expect(results.first.label, 'Production Server');
    });

    test('search finds hosts by hostname', () async {
      await repository.insert(
        HostsCompanion.insert(
          label: 'Server 1',
          hostname: 'prod.example.com',
          username: 'admin',
        ),
      );
      await repository.insert(
        HostsCompanion.insert(
          label: 'Server 2',
          hostname: 'dev.example.com',
          username: 'dev',
        ),
      );

      final results = await repository.search('prod');
      expect(results, hasLength(1));
      expect(results.first.hostname, 'prod.example.com');
    });

    test('search finds hosts by tags', () async {
      await repository.insert(
        HostsCompanion.insert(
          label: 'Tagged Server',
          hostname: 'tagged.example.com',
          username: 'admin',
          tags: const Value('prod,critical'),
        ),
      );
      await repository.insert(
        HostsCompanion.insert(
          label: 'Other Server',
          hostname: 'other.example.com',
          username: 'admin',
          tags: const Value('dev'),
        ),
      );

      final results = await repository.search('critical');
      expect(results, hasLength(1));
      expect(results.first.label, 'Tagged Server');
    });

    // Wildcard-safety tests: % and _ in the query must be treated as
    // literal characters, not as SQL LIKE metacharacters.

    test(
      'search treats percent as a literal character, not a wildcard',
      () async {
        await repository.insert(
          HostsCompanion.insert(
            label: '99% uptime',
            hostname: 'uptime.example.com',
            username: 'admin',
          ),
        );
        await repository.insert(
          HostsCompanion.insert(
            label: 'No special chars',
            hostname: 'normal.example.com',
            username: 'admin',
          ),
        );

        // Without escaping, '%' would match every host; with escaping it
        // matches only hosts that literally contain '%'.
        final results = await repository.search('%');
        expect(results, hasLength(1));
        expect(results.first.label, '99% uptime');
      },
    );

    test(
      'search treats underscore as a literal character, not a wildcard',
      () async {
        await repository.insert(
          HostsCompanion.insert(
            label: 'web_server',
            hostname: 'web.example.com',
            username: 'admin',
          ),
        );
        await repository.insert(
          HostsCompanion.insert(
            label: 'api server',
            hostname: 'api.example.com',
            username: 'admin',
          ),
        );

        // 'web_' should match only the host whose label contains the literal
        // substring "web_", not "web" followed by any single character.
        final results = await repository.search('web_');
        expect(results, hasLength(1));
        expect(results.first.label, 'web_server');
      },
    );

    test(
      'search with percent does not return hosts that lack a literal percent',
      () async {
        await repository.insert(
          HostsCompanion.insert(
            label: 'Normal Server',
            hostname: 'normal.example.com',
            username: 'admin',
          ),
        );

        // A bare '%' query should return nothing when no host data contains '%'.
        final results = await repository.search('%');
        expect(results, isEmpty);
      },
    );

    test(
      'search with underscore does not cross-match non-underscore hosts',
      () async {
        await repository.insert(
          HostsCompanion.insert(
            label: 'abc',
            hostname: 'abc.example.com',
            username: 'admin',
          ),
        );

        // Without escaping, 'a_c' would match 'abc' (any single char between
        // a and c). With escaping it should return nothing.
        final results = await repository.search('a_c');
        expect(results, isEmpty);
      },
    );

    test('getByGroup returns hosts with null groupId', () async {
      await repository.insert(
        HostsCompanion.insert(
          label: 'Ungrouped Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      final hosts = await repository.getByGroup(null);
      expect(hosts, hasLength(1));
      expect(hosts.first.label, 'Ungrouped Server');
    });

    test('getByGroup returns hosts with specific groupId', () async {
      // Create a group first
      final groupId = await db
          .into(db.groups)
          .insert(GroupsCompanion.insert(name: 'Test Group'));

      await repository.insert(
        HostsCompanion.insert(
          label: 'Grouped Server',
          hostname: '192.168.1.1',
          username: 'admin',
          groupId: Value(groupId),
        ),
      );
      await repository.insert(
        HostsCompanion.insert(
          label: 'Ungrouped Server',
          hostname: '192.168.1.2',
          username: 'admin',
        ),
      );

      final hosts = await repository.getByGroup(groupId);
      expect(hosts, hasLength(1));
      expect(hosts.first.label, 'Grouped Server');
    });

    test('updateLastConnected updates timestamp', () async {
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      var host = await repository.getById(id);
      expect(host!.lastConnectedAt, isNull);

      await repository.updateLastConnected(id);

      host = await repository.getById(id);
      expect(host!.lastConnectedAt, isNotNull);
    });

    test('updateLastConnected returns false when host not exists', () async {
      final result = await repository.updateLastConnected(999);
      expect(result, isFalse);
    });

    test('watchAll emits updates', () async {
      await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      final stream = repository.watchAll();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('watchFavorites emits updates', () async {
      final id = await repository.insert(
        HostsCompanion.insert(
          label: 'Test Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );
      await repository.toggleFavorite(id);

      final stream = repository.watchFavorites();
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('watchByGroup emits for null group', () async {
      await repository.insert(
        HostsCompanion.insert(
          label: 'Ungrouped Server',
          hostname: '192.168.1.1',
          username: 'admin',
        ),
      );

      final stream = repository.watchByGroup(null);
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });

    test('watchByGroup emits for specific group', () async {
      final groupId = await db
          .into(db.groups)
          .insert(GroupsCompanion.insert(name: 'Test Group'));

      await repository.insert(
        HostsCompanion.insert(
          label: 'Grouped Server',
          hostname: '192.168.1.1',
          username: 'admin',
          groupId: Value(groupId),
        ),
      );

      final stream = repository.watchByGroup(groupId);
      final firstValue = await stream.first;
      expect(firstValue, hasLength(1));
    });
  });
}
