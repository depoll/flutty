import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// ignore_for_file: public_member_api_docs

import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/background_ssh_service.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:xterm/xterm.dart';

const _backgroundSshChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/ssh_service',
);

class _CapturingSshService extends SshService {
  _CapturingSshService({
    required super.hostRepository,
    required super.keyRepository,
  });

  SshConnectionConfig? capturedConfig;

  @override
  Future<SshConnectionResult> connect(
    SshConnectionConfig config, {
    ConnectionProgressCallback? onProgress,
    bool isJumpHost = false,
  }) async {
    capturedConfig = config;
    return const SshConnectionResult(success: false, error: 'stubbed');
  }
}

class _CountingKeyRepository extends KeyRepository {
  _CountingKeyRepository(
    super.db,
    super.secretEncryptionService, {
    this.returnNullOnGetById = false,
  });

  final bool returnNullOnGetById;
  int getAllCallCount = 0;

  @override
  Future<List<SshKey>> getAll() async {
    getAllCallCount++;
    return super.getAll();
  }

  @override
  Future<SshKey?> getById(int id) async {
    if (returnNullOnGetById) {
      return null;
    }
    return super.getById(id);
  }
}

class _MockSshClient extends Mock implements SSHClient {}

class _FakeHostKeySocket implements SSHSocket, HostKeySource {
  _FakeHostKeySocket(this._hostKeyBytes);

  final Uint8List _hostKeyBytes;
  final _streamController = StreamController<Uint8List>();
  final _sinkController = StreamController<List<int>>();

  @override
  Future<Uint8List> get hostKeyBytes async => _hostKeyBytes;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> close() async {
    await _streamController.close();
    await _sinkController.close();
  }

  @override
  Future<void> get done async {}

  @override
  void destroy() {}
}

class _FakeForwardHostKeySocket implements SSHForwardChannel, HostKeySource {
  _FakeForwardHostKeySocket(this._hostKeyBytes);

  final Uint8List _hostKeyBytes;
  final _streamController = StreamController<Uint8List>();
  final _sinkController = StreamController<List<int>>();

  @override
  Future<Uint8List> get hostKeyBytes async => _hostKeyBytes;

  @override
  Stream<Uint8List> get stream => _streamController.stream;

  @override
  StreamSink<List<int>> get sink => _sinkController.sink;

  @override
  Future<void> close() async {
    await _streamController.close();
    await _sinkController.close();
  }

  @override
  Future<void> get done async {}

  @override
  void destroy() {}
}

class _FakeActiveSessionsSshService extends SshService {
  final Map<int, SshSession> _sessions = {};
  int _nextConnectionId = 1;

  @override
  Map<int, SshSession> get sessions => Map.unmodifiable(_sessions);

  @override
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
  }) async {
    final connectionId = _nextConnectionId++;
    final session = SshSession(
      connectionId: connectionId,
      hostId: hostId,
      client: _MockSshClient(),
      config: SshConnectionConfig(
        hostname: 'host-$hostId.example.com',
        port: 22,
        username: 'tester',
      ),
    );
    _sessions[connectionId] = session;
    return SshConnectionResult(success: true, connectionId: connectionId);
  }

  @override
  Future<void> disconnect(int connectionId) async {
    _sessions.remove(connectionId);
  }

  @override
  Future<void> disconnectAll() async {
    _sessions.clear();
  }

  @override
  SshSession? getSession(int connectionId) => _sessions[connectionId];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('terminal metadata helpers', () {
    test('parses and formats working directory metadata', () {
      final uri = parseTerminalWorkingDirectoryUri([
        'file://remote.example.com/Users/tester/project%20name',
      ]);

      expect(uri, isNotNull);
      expect(
        resolveTerminalWorkingDirectoryPath(uri),
        '/Users/tester/project name',
      );
      expect(
        formatTerminalWorkingDirectoryLabel(uri),
        'remote.example.com:/Users/tester/project name',
      );
    });

    test('falls back to the raw working-directory path on bad encoding', () {
      final uri = Uri.parse('file://remote.example.com/Users/tester/100%');

      expect(resolveTerminalWorkingDirectoryPath(uri), '/Users/tester/100%');
      expect(
        formatTerminalWorkingDirectoryLabel(uri),
        'remote.example.com:/Users/tester/100%',
      );
    });

    test('preserves shell state transitions and exit codes', () {
      final promptState = applyTerminalShellIntegrationOsc(
        const ['A'],
        previousStatus: null,
        previousExitCode: null,
      );
      expect(promptState.status, TerminalShellStatus.prompt);
      expect(promptState.lastExitCode, isNull);

      final runningState = applyTerminalShellIntegrationOsc(
        const ['C'],
        previousStatus: promptState.status,
        previousExitCode: promptState.lastExitCode,
      );
      expect(runningState.status, TerminalShellStatus.runningCommand);
      expect(runningState.lastExitCode, isNull);

      final exitState = applyTerminalShellIntegrationOsc(
        const ['D', '17'],
        previousStatus: runningState.status,
        previousExitCode: runningState.lastExitCode,
      );
      expect(exitState.status, TerminalShellStatus.prompt);
      expect(exitState.lastExitCode, 17);
      expect(
        describeTerminalShellStatus(
          exitState.status,
          lastExitCode: exitState.lastExitCode,
        ),
        'Exit 17',
      );
    });

    test(
      'preserves the previous exit code when OSC 133 exit code is invalid',
      () {
        final exitState = applyTerminalShellIntegrationOsc(
          const ['D', 'bad'],
          previousStatus: TerminalShellStatus.runningCommand,
          previousExitCode: 17,
        );

        expect(exitState.status, TerminalShellStatus.prompt);
        expect(exitState.lastExitCode, 17);
      },
    );
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
      expect(config.identityKeys, isNull);
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
      expect(config.identityKeys, isNull);
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
        expect(config.identityKeys, isNull);
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
        expect(config.identityKeys, isNull);
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
        expect(config.identityKeys, isNull);
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

  group('SshSession terminal previews', () {
    test('builds preview from the latest non-empty lines', () {
      final terminal = Terminal(maxLines: 100)
        ..write('first line\r\nsecond line\r\n\r\nthird line');

      final preview = SshSession.buildTerminalPreview(terminal, maxLines: 2);

      expect(preview, 'second line\nthird line');
    });

    test('sanitizes control characters and truncates long previews', () {
      final terminal = Terminal(maxLines: 100)
        ..write('prompt> \u0007hello world\r\n')
        ..write(List<String>.filled(80, 'x').join());

      final preview = SshSession.buildTerminalPreview(terminal, maxChars: 40);

      expect(preview, isNotNull);
      expect(preview, isNot(contains('\u0007')));
      expect(preview, startsWith('…'));
      expect(preview, contains('xxxxxxxx'));
    });

    test('clamps invalid preview limits to safe minimums', () {
      final terminal = Terminal(maxLines: 100)..write('alpha\r\nbeta');

      expect(
        SshSession.buildTerminalPreview(terminal, maxLines: 0, maxChars: 4),
        'beta',
      );
      expect(SshSession.buildTerminalPreview(terminal, maxChars: 0), '…');
    });
  });

  group('ActiveSessionsNotifier', () {
    late ProviderContainer container;
    late _FakeActiveSessionsSshService fakeSshService;
    late List<MethodCall> methodCalls;

    setUp(() {
      fakeSshService = _FakeActiveSessionsSshService();
      methodCalls = <MethodCall>[];
      BackgroundSshService.debugIsSupportedPlatformOverride = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, (call) async {
            methodCalls.add(call);
            return null;
          });
      container = ProviderContainer(
        overrides: [sshServiceProvider.overrideWithValue(fakeSshService)],
      );
    });

    tearDown(() async {
      BackgroundSshService.debugIsSupportedPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, null);
      container.dispose();
    });

    test(
      'syncBackgroundStatus stops the background service when empty',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);

        await notifier.syncBackgroundStatus();

        expect(methodCalls, hasLength(1));
        expect(methodCalls.single.method, 'stopService');
      },
    );

    test('syncBackgroundStatus publishes counts for active sessions', () async {
      final notifier = container.read(activeSessionsProvider.notifier);

      final result = await notifier.connect(42, forceNew: true);
      expect(result.success, isTrue);

      await Future<void>.delayed(Duration.zero);
      methodCalls.clear();
      await notifier.syncBackgroundStatus();

      expect(methodCalls, hasLength(1));
      expect(methodCalls.single.method, 'updateStatus');
      final arguments = Map<String, Object?>.from(
        methodCalls.single.arguments as Map<Object?, Object?>,
      );
      expect(arguments, <String, Object?>{
        'connectionCount': 1,
        'connectedCount': 1,
      });
    });

    test('syncBackgroundStatus serializes queued updates', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final firstCallStarted = Completer<void>();
      final releaseFirstCall = Completer<void>();
      var activeCalls = 0;
      var maxConcurrentCalls = 0;
      var updateCallCount = 0;

      await notifier.connect(7, forceNew: true);
      await Future<void>.delayed(Duration.zero);
      methodCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_backgroundSshChannel, (call) async {
            if (call.method != 'updateStatus') {
              return null;
            }
            updateCallCount++;
            activeCalls++;
            if (activeCalls > maxConcurrentCalls) {
              maxConcurrentCalls = activeCalls;
            }
            if (updateCallCount == 1) {
              firstCallStarted.complete();
              await releaseFirstCall.future;
            }
            activeCalls--;
            return null;
          });

      final firstSync = notifier.syncBackgroundStatus();
      await firstCallStarted.future;
      final secondSync = notifier.syncBackgroundStatus();
      await Future<void>.delayed(Duration.zero);

      expect(updateCallCount, 1);

      releaseFirstCall.complete();
      await Future.wait<void>([firstSync, secondSync]);

      expect(updateCallCount, 2);
      expect(maxConcurrentCalls, 1);
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

    test('connectToHost uses Auto keys when host has no password', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Auto Key 1',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 AAAA...',
          privateKey: 'private-key-1',
        ),
      );
      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Auto Key 2',
          keyType: 'rsa',
          publicKey: 'ssh-rsa BBBB...',
          privateKey: 'private-key-2',
        ),
      );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Auto Host',
              hostname: '10.0.0.10',
              username: 'admin',
            ),
          );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.privateKey, isNull);
      expect(config.identityKeys, hasLength(2));
    });

    test('connectToHost caps Auto keys to avoid auth lockout', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      for (var i = 0; i < 7; i++) {
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key $i',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 KEY$i',
            privateKey: 'private-key-$i',
          ),
        );
      }
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Auto Host',
              hostname: '10.0.0.13',
              username: 'admin',
            ),
          );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.identityKeys, hasLength(5));
      expect(config.identityKeys!.map((key) => key.name).toList(), [
        'Auto Key 0',
        'Auto Key 1',
        'Auto Key 2',
        'Auto Key 3',
        'Auto Key 4',
      ]);
    });

    test(
      'connectToHost fetches Auto keys once for host and jump host',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryptionService = SecretEncryptionService.forTesting();
        final hostRepo = HostRepository(db, encryptionService);
        final keyRepo = _CountingKeyRepository(db, encryptionService);
        final service = _CapturingSshService(
          hostRepository: hostRepo,
          keyRepository: keyRepo,
        );

        final jumpHostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Jump Host',
                hostname: '10.0.0.20',
                username: 'jump',
              ),
            );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Target Host',
                hostname: '10.0.0.21',
                username: 'target',
                jumpHostId: Value(jumpHostId),
              ),
            );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key 1',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 AAAA...',
            privateKey: 'private-key-1',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key 2',
            keyType: 'rsa',
            publicKey: 'ssh-rsa BBBB...',
            privateKey: 'private-key-2',
          ),
        );

        await service.connectToHost(hostId);

        final config = service.capturedConfig;
        expect(config, isNotNull);
        expect(config!.identityKeys, hasLength(2));
        expect(config.jumpHost, isNotNull);
        expect(config.jumpHost!.identityKeys, hasLength(2));
        expect(keyRepo.getAllCallCount, 1);
      },
    );

    test('connectToHost keeps explicit key override', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      final selectedKeyId = await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Selected Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 CCCC...',
          privateKey: 'selected-private-key',
        ),
      );
      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Other Key',
          keyType: 'rsa',
          publicKey: 'ssh-rsa DDDD...',
          privateKey: 'other-private-key',
        ),
      );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Pinned Key Host',
              hostname: '10.0.0.11',
              username: 'root',
              keyId: Value(selectedKeyId),
            ),
          );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.privateKey, 'selected-private-key');
      expect(config.identityKeys, isNull);
    });

    test(
      'connectToHost falls back to Auto keys when selected key is missing',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryptionService = SecretEncryptionService.forTesting();
        final hostRepo = HostRepository(db, encryptionService);
        final keyRepo = _CountingKeyRepository(
          db,
          encryptionService,
          returnNullOnGetById: true,
        );
        final service = _CapturingSshService(
          hostRepository: hostRepo,
          keyRepository: keyRepo,
        );

        final selectedKeyId = await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Selected Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 CCCC...',
            privateKey: 'selected-private-key',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key',
            keyType: 'rsa',
            publicKey: 'ssh-rsa DDDD...',
            privateKey: 'auto-private-key',
          ),
        );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Pinned Key Host',
                hostname: '10.0.0.30',
                username: 'root',
                keyId: Value(selectedKeyId),
              ),
            );

        await service.connectToHost(hostId);

        final config = service.capturedConfig;
        expect(config, isNotNull);
        expect(config!.privateKey, isNull);
        expect(config.identityKeys, hasLength(2));
      },
    );

    test(
      'connectToHost falls back to Auto keys for jump host when selected key is missing',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final encryptionService = SecretEncryptionService.forTesting();
        final hostRepo = HostRepository(db, encryptionService);
        final keyRepo = _CountingKeyRepository(
          db,
          encryptionService,
          returnNullOnGetById: true,
        );
        final service = _CapturingSshService(
          hostRepository: hostRepo,
          keyRepository: keyRepo,
        );

        final selectedJumpKeyId = await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Selected Jump Key',
            keyType: 'ed25519',
            publicKey: 'ssh-ed25519 EEEE...',
            privateKey: 'selected-jump-private-key',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key',
            keyType: 'rsa',
            publicKey: 'ssh-rsa FFFF...',
            privateKey: 'auto-private-key',
          ),
        );
        final jumpHostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Jump Host',
                hostname: '10.0.0.31',
                username: 'jump',
                keyId: Value(selectedJumpKeyId),
              ),
            );
        final hostId = await db
            .into(db.hosts)
            .insert(
              HostsCompanion.insert(
                label: 'Target Host',
                hostname: '10.0.0.32',
                username: 'target',
                jumpHostId: Value(jumpHostId),
              ),
            );

        await service.connectToHost(hostId);

        final config = service.capturedConfig;
        expect(config, isNotNull);
        expect(config!.jumpHost, isNotNull);
        expect(config.jumpHost!.privateKey, isNull);
        expect(config.jumpHost!.identityKeys, hasLength(2));
      },
    );

    test('connectToHost skips Auto keys when host has a password', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryptionService);
      final keyRepo = KeyRepository(db, encryptionService);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
      );

      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Unused Auto Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 EEEE...',
          privateKey: 'unused-private-key',
        ),
      );
      final hostId = await hostRepo.insert(
        HostsCompanion.insert(
          label: 'Password Host',
          hostname: '10.0.0.12',
          username: 'admin',
          password: const Value('secret'),
        ),
      );

      await service.connectToHost(hostId);

      final config = service.capturedConfig;
      expect(config, isNotNull);
      expect(config!.password, 'secret');
      expect(config.identityKeys, isNull);
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

    test('connect verifies jump-host and destination host keys', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final jumpSocket = _FakeHostKeySocket(_ed25519HostKeyBlob([1, 2, 3]));
      final targetSocket = _FakeForwardHostKeySocket(
        _ed25519HostKeyBlob([4, 5, 6]),
      );
      final jumpClient = _MockSshClient();
      final targetClient = _MockSshClient();
      var clientIndex = 0;

      when(
        () => jumpClient.forwardLocal('target.example.com', 22),
      ).thenAnswer(_returnTargetSocket(targetSocket));
      when(jumpClient.close).thenReturn(null);
      when(targetClient.close).thenReturn(null);

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async => HostKeyTrustDecision.trust,
        socketConnector: (host, port, {timeout}) async {
          expect(host, 'jump.example.com');
          expect(port, 2222);
          return jumpSocket;
        },
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              identities,
              keepAliveInterval,
            }) {
              final client = clientIndex == 0 ? jumpClient : targetClient;
              final hostKeyBytes = socket is HostKeySource
                  ? (socket as HostKeySource).hostKeyBytes
                  : Future<Uint8List>.value(Uint8List(0));
              if (clientIndex == 0) {
                when(() => jumpClient.authenticated).thenAnswer((_) async {
                  final bytes = await hostKeyBytes;
                  await onVerifyHostKey!(
                    'ssh-ed25519',
                    Uint8List.fromList(md5.convert(bytes).bytes),
                  );
                });
              } else {
                when(() => targetClient.authenticated).thenAnswer((_) async {
                  final bytes = await hostKeyBytes;
                  await onVerifyHostKey!(
                    'ssh-ed25519',
                    Uint8List.fromList(md5.convert(bytes).bytes),
                  );
                });
              }
              clientIndex++;
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'target.example.com',
        port: 22,
        username: 'target',
        jumpHost: SshConnectionConfig(
          hostname: 'jump.example.com',
          port: 2222,
          username: 'jump',
        ),
      );

      final result = await service.connect(config);

      expect(result.success, isTrue);
      expect(
        await knownHostsRepository.getByHost('jump.example.com', 2222),
        isNotNull,
      );
      expect(
        await knownHostsRepository.getByHost('target.example.com', 22),
        isNotNull,
      );
    });

    test(
      'connect persists accepted TOFU trust before authentication succeeds',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final knownHostsRepository = KnownHostsRepository(db);
        final socket = _FakeHostKeySocket(_ed25519HostKeyBlob([7, 8, 9]));
        final client = _MockSshClient();

        when(client.close).thenReturn(null);

        final service = SshService(
          knownHostsRepository: knownHostsRepository,
          hostKeyPromptHandler: (_) async => HostKeyTrustDecision.trust,
          socketConnector: (host, port, {timeout}) async => socket,
          clientFactory:
              (
                socket, {
                required username,
                onVerifyHostKey,
                onPasswordRequest,
                identities,
                keepAliveInterval,
              }) {
                when(() => client.authenticated).thenAnswer((_) async {
                  final bytes = await (socket as HostKeySource).hostKeyBytes;
                  await onVerifyHostKey!(
                    'ssh-ed25519',
                    Uint8List.fromList(md5.convert(bytes).bytes),
                  );
                  return Future<void>.error(
                    SSHAuthFailError('Authentication failed'),
                  );
                });
                return client;
              },
        );

        const config = SshConnectionConfig(
          hostname: 'persist.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config);

        expect(result.success, isFalse);
        expect(
          await knownHostsRepository.getByHost('persist.example.com', 22),
          isNotNull,
        );
      },
    );

    test('sessions map is unmodifiable', () {
      expect(
        () => (sshService.sessions as Map)[1] = 'test',
        throwsA(isA<Error>()),
      );
    });
  });
}

Uint8List _ed25519HostKeyBlob(List<int> keyData) {
  final typeBytes = utf8.encode('ssh-ed25519');
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(typeBytes.length))
    ..add(typeBytes)
    ..add(_uint32(keyData.length))
    ..add(keyData);
  return writer.takeBytes();
}

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);

Answer<Future<SSHForwardChannel>> _returnTargetSocket(
  SSHForwardChannel socket,
) =>
    (_) async => socket;
