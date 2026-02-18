// ignore_for_file: public_member_api_docs

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

void main() {
  group('SshConnectionState', () {
    test('has expected values', () {
      expect(SshConnectionState.values, hasLength(6));
      expect(SshConnectionState.disconnected, isNotNull);
      expect(SshConnectionState.connecting, isNotNull);
      expect(SshConnectionState.authenticating, isNotNull);
      expect(SshConnectionState.connected, isNotNull);
      expect(SshConnectionState.error, isNotNull);
      expect(SshConnectionState.reconnecting, isNotNull);
    });
  });

  group('SshConnectionConfig', () {
    test('creates with required fields', () {
      const config = SshConnectionConfig(
        hostname: 'example.com',
        port: 22,
        username: 'user',
      );

      expect(config.hostname, 'example.com');
      expect(config.port, 22);
      expect(config.username, 'user');
      expect(config.password, isNull);
      expect(config.privateKey, isNull);
      expect(config.passphrase, isNull);
      expect(config.jumpHost, isNull);
      expect(config.keepAliveInterval, const Duration(seconds: 30));
      expect(config.connectionTimeout, const Duration(seconds: 30));
    });

    test('creates with all fields', () {
      const jumpConfig = SshConnectionConfig(
        hostname: 'jump.example.com',
        port: 2222,
        username: 'jumpuser',
      );
      const config = SshConnectionConfig(
        hostname: 'target.example.com',
        port: 22,
        username: 'user',
        password: 'pass123',
        privateKey: '-----BEGIN KEY-----',
        passphrase: 'secret',
        jumpHost: jumpConfig,
        keepAliveInterval: Duration(seconds: 60),
        connectionTimeout: Duration(seconds: 15),
      );

      expect(config.hostname, 'target.example.com');
      expect(config.port, 22);
      expect(config.username, 'user');
      expect(config.password, 'pass123');
      expect(config.privateKey, '-----BEGIN KEY-----');
      expect(config.passphrase, 'secret');
      expect(config.jumpHost, isNotNull);
      expect(config.jumpHost!.hostname, 'jump.example.com');
      expect(config.jumpHost!.port, 2222);
      expect(config.jumpHost!.username, 'jumpuser');
      expect(config.keepAliveInterval, const Duration(seconds: 60));
      expect(config.connectionTimeout, const Duration(seconds: 15));
    });

    group('fromHost', () {
      late AppDatabase db;

      setUp(() {
        db = AppDatabase.forTesting(NativeDatabase.memory());
      });

      tearDown(() async {
        await db.close();
      });

      test('creates config from host without key', () async {
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Test Host',
                hostname: '10.0.0.1',
                username: 'root',
                port: const Value(2222),
                password: const Value('pass'),
              ),
            );
        final host = await (db.select(
          db.hosts,
        )..where((t) => t.id.equals(hostId))).getSingle();

        final config = SshConnectionConfig.fromHost(host);

        expect(config.hostname, '10.0.0.1');
        expect(config.port, 2222);
        expect(config.username, 'root');
        expect(config.password, 'pass');
        expect(config.privateKey, isNull);
        expect(config.jumpHost, isNull);
      });

      test('creates config from host with key', () async {
        final keyId = await db
            .into(db.sshKeys)
            .insert(
              SshKeysCompanion.insert(
                name: 'Test Key',
                keyType: 'ed25519',
                publicKey: 'ssh-ed25519 AAAA...',
                privateKey:
                    '-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----',
                passphrase: const Value('keypass'),
              ),
            );
        final key = await (db.select(
          db.sshKeys,
        )..where((t) => t.id.equals(keyId))).getSingle();
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Key Host',
                hostname: '10.0.0.2',
                username: 'admin',
                keyId: Value(keyId),
              ),
            );
        final host = await (db.select(
          db.hosts,
        )..where((t) => t.id.equals(hostId))).getSingle();

        final config = SshConnectionConfig.fromHost(host, key: key);

        expect(config.hostname, '10.0.0.2');
        expect(config.username, 'admin');
        expect(config.privateKey, contains('BEGIN OPENSSH PRIVATE KEY'));
        expect(config.passphrase, 'keypass');
      });

      test('creates config with jump host', () async {
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Target Host',
                hostname: '10.0.0.3',
                username: 'deploy',
              ),
            );
        final host = await (db.select(
          db.hosts,
        )..where((t) => t.id.equals(hostId))).getSingle();

        const jumpConfig = SshConnectionConfig(
          hostname: 'bastion.example.com',
          port: 22,
          username: 'jumpuser',
        );

        final config = SshConnectionConfig.fromHost(
          host,
          jumpHostConfig: jumpConfig,
        );

        expect(config.hostname, '10.0.0.3');
        expect(config.jumpHost, isNotNull);
        expect(config.jumpHost!.hostname, 'bastion.example.com');
      });
    });
  });

  group('SshConnectionResult', () {
    test('creates success result', () {
      const result = SshConnectionResult(success: true);

      expect(result.success, isTrue);
      expect(result.error, isNull);
      expect(result.client, isNull);
    });

    test('creates failure result with error', () {
      const result = SshConnectionResult(
        success: false,
        error: 'Connection refused',
      );

      expect(result.success, isFalse);
      expect(result.error, 'Connection refused');
      expect(result.client, isNull);
    });
  });

  group('ActiveTunnelInfo', () {
    test('creates with required fields', () {
      const info = ActiveTunnelInfo(
        portForwardId: 1,
        localPort: 3306,
        remoteHost: 'db.internal',
        remotePort: 3306,
        isLocal: true,
      );

      expect(info.portForwardId, 1);
      expect(info.localPort, 3306);
      expect(info.remoteHost, 'db.internal');
      expect(info.remotePort, 3306);
      expect(info.isLocal, isTrue);
    });

    test('supports remote forward info', () {
      const info = ActiveTunnelInfo(
        portForwardId: 2,
        localPort: 8080,
        remoteHost: 'localhost',
        remotePort: 80,
        isLocal: false,
      );

      expect(info.isLocal, isFalse);
    });
  });

  group('SshService', () {
    late SshService sshService;

    setUp(() {
      sshService = SshService();
    });

    test('starts with no sessions', () {
      expect(sshService.sessions, isEmpty);
    });

    test('isConnected returns false for unknown host', () {
      expect(sshService.isConnected(999), isFalse);
    });

    test('getSession returns null for unknown host', () {
      expect(sshService.getSession(999), isNull);
    });

    test('connectToHost fails without host repository', () async {
      final result = await sshService.connectToHost(1);

      expect(result.success, isFalse);
      expect(result.error, 'Host repository not available');
    });

    test('disconnect is safe for unknown host', () async {
      // Should not throw
      await sshService.disconnect(999);
    });

    test('disconnectAll is safe with no sessions', () async {
      // Should not throw
      await sshService.disconnectAll();
    });

    test('connectToHost fails when host not found', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = SshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      final result = await service.connectToHost(999);

      expect(result.success, isFalse);
      expect(result.error, 'Host not found');

      await db.close();
    });

    test('connect fails with invalid hostname', () async {
      const config = SshConnectionConfig(
        hostname: 'nonexistent.invalid.host.test',
        port: 22,
        username: 'user',
        connectionTimeout: Duration(seconds: 2),
      );

      final result = await sshService.connect(config);

      expect(result.success, isFalse);
      expect(result.error, isNotNull);
    });

    test('sessions map is unmodifiable', () {
      expect(
        () => (sshService.sessions as Map)[1] = 'test',
        throwsA(isA<Error>()),
      );
    });
  });
}
