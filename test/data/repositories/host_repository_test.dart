// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutty/data/database/database.dart';
import 'package:flutty/data/repositories/host_repository.dart';

void main() {
  late AppDatabase db;
  late HostRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = HostRepository(db);
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
