// ignore_for_file: public_member_api_docs

import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:path/path.dart' as p;

void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('Hosts table', () {
    test('insert and retrieve host', () async {
      final id = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Test Server',
              hostname: '192.168.1.1',
              username: 'admin',
            ),
          );

      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingle();

      expect(host.label, 'Test Server');
      expect(host.hostname, '192.168.1.1');
      expect(host.username, 'admin');
      expect(host.port, 22); // default
      expect(host.isFavorite, false); // default
    });

    test('update host', () async {
      final id = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Test Server',
              hostname: '192.168.1.1',
              username: 'admin',
            ),
          );

      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingle();

      await db
          .update(db.hosts)
          .replace(host.copyWith(label: 'Updated Server', isFavorite: true));

      final updated = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingle();

      expect(updated.label, 'Updated Server');
      expect(updated.isFavorite, true);
    });

    test('delete host', () async {
      final id = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Test Server',
              hostname: '192.168.1.1',
              username: 'admin',
            ),
          );

      await (db.delete(db.hosts)..where((h) => h.id.equals(id))).go();

      final host = await (db.select(
        db.hosts,
      )..where((h) => h.id.equals(id))).getSingleOrNull();

      expect(host, isNull);
    });

    test('list all hosts', () async {
      await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Server 1',
              hostname: '192.168.1.1',
              username: 'admin',
            ),
          );
      await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Server 2',
              hostname: '192.168.1.2',
              username: 'root',
            ),
          );

      final hosts = await db.select(db.hosts).get();

      expect(hosts, hasLength(2));
    });
  });

  group('SSH Keys table', () {
    test('insert and retrieve key', () async {
      final id = await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'My Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 AAAA...',
              privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----...',
            ),
          );

      final key = await (db.select(
        db.sshKeys,
      )..where((k) => k.id.equals(id))).getSingle();

      expect(key.name, 'My Key');
      expect(key.keyType, 'ed25519');
    });
  });

  group('Groups table', () {
    test('insert and retrieve group', () async {
      final id = await db
          .into(db.groups)
          .insert(GroupsCompanion.insert(name: 'Production'));

      final group = await (db.select(
        db.groups,
      )..where((g) => g.id.equals(id))).getSingle();

      expect(group.name, 'Production');
      expect(group.parentId, isNull);
    });

    test('create nested groups', () async {
      final parentId = await db
          .into(db.groups)
          .insert(GroupsCompanion.insert(name: 'Cloud'));

      final childId = await db
          .into(db.groups)
          .insert(
            GroupsCompanion.insert(name: 'AWS', parentId: Value(parentId)),
          );

      final child = await (db.select(
        db.groups,
      )..where((g) => g.id.equals(childId))).getSingle();

      expect(child.parentId, parentId);
    });
  });

  group('Snippets table', () {
    test('insert and retrieve snippet', () async {
      final id = await db
          .into(db.snippets)
          .insert(
            SnippetsCompanion.insert(name: 'List files', command: 'ls -la'),
          );

      final snippet = await (db.select(
        db.snippets,
      )..where((s) => s.id.equals(id))).getSingle();

      expect(snippet.name, 'List files');
      expect(snippet.command, 'ls -la');
      expect(snippet.usageCount, 0);
    });

    test('increment usage count', () async {
      final id = await db
          .into(db.snippets)
          .insert(
            SnippetsCompanion.insert(name: 'List files', command: 'ls -la'),
          );

      var snippet = await (db.select(
        db.snippets,
      )..where((s) => s.id.equals(id))).getSingle();

      await db
          .update(db.snippets)
          .replace(snippet.copyWith(usageCount: snippet.usageCount + 1));

      snippet = await (db.select(
        db.snippets,
      )..where((s) => s.id.equals(id))).getSingle();

      expect(snippet.usageCount, 1);
    });
  });

  group('Settings table', () {
    test('insert and retrieve setting', () async {
      await db
          .into(db.settings)
          .insert(SettingsCompanion.insert(key: 'theme_mode', value: 'dark'));

      final setting = await (db.select(
        db.settings,
      )..where((s) => s.key.equals('theme_mode'))).getSingle();

      expect(setting.value, 'dark');
    });

    test('upsert setting', () async {
      await db
          .into(db.settings)
          .insertOnConflictUpdate(
            SettingsCompanion.insert(key: 'theme_mode', value: 'dark'),
          );

      await db
          .into(db.settings)
          .insertOnConflictUpdate(
            SettingsCompanion.insert(key: 'theme_mode', value: 'light'),
          );

      final settings = await db.select(db.settings).get();
      expect(settings, hasLength(1));
      expect(settings.first.value, 'light');
    });
  });

  group('Port Forwards table', () {
    test('insert and retrieve port forward', () async {
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Test Server',
              hostname: '192.168.1.1',
              username: 'admin',
            ),
          );

      final id = await db
          .into(db.portForwards)
          .insert(
            PortForwardsCompanion.insert(
              name: 'MySQL Tunnel',
              hostId: hostId,
              forwardType: 'local',
              localPort: 3307,
              remoteHost: 'localhost',
              remotePort: 3306,
            ),
          );

      final forward = await (db.select(
        db.portForwards,
      )..where((p) => p.id.equals(id))).getSingle();

      expect(forward.name, 'MySQL Tunnel');
      expect(forward.localPort, 3307);
      expect(forward.remotePort, 3306);
      expect(forward.hostId, hostId);
    });
  });

  group('Database storage path', () {
    test('migrates legacy flutty.db from documents to app support', () async {
      final rootDirectory = await Directory.systemTemp.createTemp(
        'flutty-db-migration-test-',
      );
      addTearDown(() async {
        if (rootDirectory.existsSync()) {
          await rootDirectory.delete(recursive: true);
        }
      });

      final documentsDirectory = Directory(p.join(rootDirectory.path, 'docs'));
      final supportDirectory = Directory(p.join(rootDirectory.path, 'support'));
      await documentsDirectory.create(recursive: true);

      final legacyFile = File(p.join(documentsDirectory.path, 'flutty.db'));
      await legacyFile.writeAsString('legacy-db');
      final legacyJournalFile = File('${legacyFile.path}-journal');
      await legacyJournalFile.writeAsString('legacy-journal');

      final resolvedFile = await resolveDatabaseFile(
        getSupportDirectory: () async => supportDirectory,
        getDocumentsDirectory: () async => documentsDirectory,
      );

      expect(resolvedFile.path, p.join(supportDirectory.path, 'flutty.db'));
      expect(resolvedFile.existsSync(), isTrue);
      expect(await resolvedFile.readAsString(), 'legacy-db');
      final migratedJournalFile = File('${resolvedFile.path}-journal');
      expect(migratedJournalFile.existsSync(), isTrue);
      expect(await migratedJournalFile.readAsString(), 'legacy-journal');
      expect(legacyFile.existsSync(), isFalse);
      expect(legacyJournalFile.existsSync(), isFalse);
    });

    test('moves legacy companion files when migration marker exists', () async {
      final rootDirectory = await Directory.systemTemp.createTemp(
        'flutty-db-companion-migration-test-',
      );
      addTearDown(() async {
        if (rootDirectory.existsSync()) {
          await rootDirectory.delete(recursive: true);
        }
      });

      final documentsDirectory = Directory(p.join(rootDirectory.path, 'docs'));
      final supportDirectory = Directory(p.join(rootDirectory.path, 'support'));
      await documentsDirectory.create(recursive: true);
      await supportDirectory.create(recursive: true);

      final supportFile = File(p.join(supportDirectory.path, 'flutty.db'));
      await supportFile.writeAsString('new-db');
      final markerFile = File(
        p.join(supportDirectory.path, 'flutty.db.legacy-migration-incomplete'),
      );
      await markerFile.writeAsString('pending');

      final legacyJournalFile = File(
        p.join(documentsDirectory.path, 'flutty.db-journal'),
      );
      await legacyJournalFile.writeAsString('legacy-journal');

      final resolvedFile = await resolveDatabaseFile(
        getSupportDirectory: () async => supportDirectory,
        getDocumentsDirectory: () async => documentsDirectory,
      );

      expect(resolvedFile.path, supportFile.path);
      final migratedJournalFile = File('${resolvedFile.path}-journal');
      expect(migratedJournalFile.existsSync(), isTrue);
      expect(await migratedJournalFile.readAsString(), 'legacy-journal');
      expect(legacyJournalFile.existsSync(), isFalse);
      expect(markerFile.existsSync(), isFalse);
    });

    test(
      'deletes orphan legacy companion files after migration completion',
      () async {
        final rootDirectory = await Directory.systemTemp.createTemp(
          'flutty-db-companion-cleanup-test-',
        );
        addTearDown(() async {
          if (rootDirectory.existsSync()) {
            await rootDirectory.delete(recursive: true);
          }
        });

        final documentsDirectory = Directory(
          p.join(rootDirectory.path, 'docs'),
        );
        final supportDirectory = Directory(
          p.join(rootDirectory.path, 'support'),
        );
        await documentsDirectory.create(recursive: true);
        await supportDirectory.create(recursive: true);

        final supportFile = File(p.join(supportDirectory.path, 'flutty.db'));
        await supportFile.writeAsString('new-db');

        final legacyJournalFile = File(
          p.join(documentsDirectory.path, 'flutty.db-journal'),
        );
        await legacyJournalFile.writeAsString('orphan-journal');

        await resolveDatabaseFile(
          getSupportDirectory: () async => supportDirectory,
          getDocumentsDirectory: () async => documentsDirectory,
        );

        expect(File('${supportFile.path}-journal').existsSync(), isFalse);
        expect(legacyJournalFile.existsSync(), isFalse);
      },
    );
  });
}
