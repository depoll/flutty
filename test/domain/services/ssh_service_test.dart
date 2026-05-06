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
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/terminal_themes.dart' as monkey_themes;
import 'package:monkeyssh/domain/services/background_ssh_service.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/wifi_network_service.dart';
import 'package:xterm/xterm.dart';

const _backgroundSshChannel = MethodChannel(
  'xyz.depollsoft.monkeyssh/ssh_service',
);

class _CapturingSshService extends SshService {
  _CapturingSshService({
    required super.hostRepository,
    required super.keyRepository,
    super.wifiNetworkService,
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

class _StubWifiNetworkService extends WifiNetworkService {
  _StubWifiNetworkService(
    this.ssid, {
    this.permissionStatus = WifiPermissionStatus.granted,
  });

  final String? ssid;
  final WifiPermissionStatus permissionStatus;
  int requestPermissionCallCount = 0;
  int getCurrentSsidCallCount = 0;

  @override
  Future<WifiPermissionStatus> requestPermission() async {
    requestPermissionCallCount++;
    return permissionStatus;
  }

  @override
  Future<String?> getCurrentSsid() async {
    getCurrentSsidCallCount++;
    return ssid;
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

class _MockExecSession extends Mock implements SSHSession {}

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
    unawaited(_streamController.close());
    unawaited(_sinkController.close());
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
    unawaited(_streamController.close());
    unawaited(_sinkController.close());
  }

  @override
  Future<void> get done async {}

  @override
  void destroy() {}
}

class _FakeActiveSessionsSshService extends SshService {
  final Map<int, SshSession> _sessions = {};
  final Map<int, Completer<void>> _clientDoneCompleters = {};
  int _nextConnectionId = 1;

  @override
  Map<int, SshSession> get sessions => Map.unmodifiable(_sessions);

  @override
  Future<SshConnectionResult> connectToHost(
    int hostId, {
    ConnectionProgressCallback? onProgress,
    bool useHostThemeOverrides = true,
  }) async {
    final connectionId = _nextConnectionId++;
    final client = _MockSshClient();
    final clientDoneCompleter = Completer<void>();
    _clientDoneCompleters[connectionId] = clientDoneCompleter;
    when(() => client.done).thenAnswer((_) => clientDoneCompleter.future);
    final session = SshSession(
      connectionId: connectionId,
      hostId: hostId,
      client: client,
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
    _clientDoneCompleters.remove(connectionId);
  }

  @override
  Future<void> disconnectAll() async {
    _sessions.clear();
    _clientDoneCompleters.clear();
  }

  @override
  SshSession? getSession(int connectionId) => _sessions[connectionId];

  void completeConnection(int connectionId) {
    final completer = _clientDoneCompleters[connectionId];
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(const SSHPtyConfig());
  registerFallbackValue(Uint8List(0));

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

    test(
      'normalizes cursor position reports to terminal protocol coordinates',
      () {
        expect(
          normalizeTerminalOutputForRemoteShell('before\x1b[0;0Rafter'),
          'before\x1b[1;1Rafter',
        );
        expect(normalizeTerminalOutputForRemoteShell('\x1b[4;7R'), '\x1b[5;8R');
      },
    );

    test('unwraps complete tmux passthrough sequences', () {
      final result = unwrapTerminalTmuxPassthroughSequences(
        input: 'before\x1bPtmux;\x1b\x1b]11;?\x07\x1b\\after',
        pendingInput: '',
      );

      expect(result.output, 'before\x1b]11;?\x07after');
      expect(result.pendingInput, isEmpty);
    });

    test('unwraps ST-terminated tmux passthrough OSC sequences', () {
      final result = unwrapTerminalTmuxPassthroughSequences(
        input: 'before\x1bPtmux;\x1b\x1b]11;?\x1b\x1b\\\x1b\\after',
        pendingInput: '',
      );

      expect(result.output, 'before\x1b]11;?\x1b\\after');
      expect(result.pendingInput, isEmpty);
    });

    test('preserves split tmux passthrough sequences across chunks', () {
      final first = unwrapTerminalTmuxPassthroughSequences(
        input: 'before\x1bPtmux;\x1b',
        pendingInput: '',
      );

      expect(first.output, 'before');
      expect(first.pendingInput, '\x1bPtmux;\x1b');

      final second = unwrapTerminalTmuxPassthroughSequences(
        input: '\x1b[?1004\$p\x1b\\after',
        pendingInput: first.pendingInput,
      );

      expect(second.output, '\x1b[?1004\$pafter');
      expect(second.pendingInput, isEmpty);
    });

    test('preserves split tmux passthrough sequence starts', () {
      final first = unwrapTerminalTmuxPassthroughSequences(
        input: 'before\x1bPtm',
        pendingInput: '',
      );

      expect(first.output, 'before');
      expect(first.pendingInput, '\x1bPtm');

      final second = unwrapTerminalTmuxPassthroughSequences(
        input: 'ux;\x1b\x1b[14t\x1b\\after',
        pendingInput: first.pendingInput,
      );

      expect(second.output, '\x1b[14tafter');
      expect(second.pendingInput, isEmpty);
    });

    test('answers terminal window and cell size reports', () {
      final result = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[14tmiddle\x1b[16tafter',
        pendingInput: '',
        metrics: const (
          columns: 80,
          rows: 24,
          pixelWidth: 960,
          pixelHeight: 480,
        ),
      );

      expect(result.response, '\x1b[4;480;960t\x1b[6;20;12t');
      expect(result.pendingInput, isEmpty);
    });

    test('preserves split terminal size report queries across chunks', () {
      final first = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[1',
        pendingInput: '',
        metrics: const (
          columns: 80,
          rows: 24,
          pixelWidth: 960,
          pixelHeight: 480,
        ),
      );

      expect(first.response, isNull);
      expect(first.pendingInput, '\x1b[1');

      final second = buildTerminalWindowControlQueryResponses(
        input: '6tafter',
        pendingInput: first.pendingInput,
        metrics: const (
          columns: 80,
          rows: 24,
          pixelWidth: 960,
          pixelHeight: 480,
        ),
      );

      expect(second.response, '\x1b[6;20;12t');
      expect(second.pendingInput, isEmpty);
    });

    test('answers terminal theme mode report queries', () {
      final dark = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[?996nafter',
        pendingInput: '',
        metrics: null,
        theme: monkey_themes.TerminalThemes.defaultDarkTheme,
      );

      expect(dark.response, '\x1b[?997;1n');
      expect(dark.pendingInput, isEmpty);

      final light = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[?996nafter',
        pendingInput: '',
        metrics: null,
        theme: monkey_themes.TerminalThemes.defaultLightTheme,
      );

      expect(light.response, '\x1b[?997;2n');
      expect(light.pendingInput, isEmpty);
    });

    test('answers DEC private mode report queries', () {
      final result = buildTerminalWindowControlQueryResponses(
        input:
            'before\x1b[?1004\$p\x1b[?2004\$p\x1b[?1006\$p'
            '\x1b[?2026\$pafter',
        pendingInput: '',
        metrics: null,
        modeState: const (
          reportFocusMode: true,
          bracketedPasteMode: false,
          colorSchemeUpdatesMode: true,
          isUsingAltBuffer: false,
          mouseTrackingMode: false,
          mouseDragTrackingMode: false,
          mouseMoveTrackingMode: false,
          sgrMouseReportMode: true,
        ),
      );

      expect(
        result.response,
        '\x1b[?1004;1\$y'
        '\x1b[?2004;2\$y'
        '\x1b[?1006;1\$y'
        '\x1b[?2026;0\$y',
      );
      expect(result.pendingInput, isEmpty);

      final colorSchemeReset = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[?2031\$pafter',
        pendingInput: '',
        metrics: null,
        modeState: const (
          reportFocusMode: false,
          bracketedPasteMode: false,
          colorSchemeUpdatesMode: false,
          isUsingAltBuffer: false,
          mouseTrackingMode: false,
          mouseDragTrackingMode: false,
          mouseMoveTrackingMode: false,
          sgrMouseReportMode: false,
        ),
      );

      expect(colorSchemeReset.response, '\x1b[?2031;2\$y');
    });

    test('preserves split DEC private mode report queries across chunks', () {
      final first = buildTerminalWindowControlQueryResponses(
        input: 'before\x1b[?1004\$',
        pendingInput: '',
        metrics: null,
        modeState: const (
          reportFocusMode: true,
          bracketedPasteMode: false,
          colorSchemeUpdatesMode: false,
          isUsingAltBuffer: false,
          mouseTrackingMode: false,
          mouseDragTrackingMode: false,
          mouseMoveTrackingMode: false,
          sgrMouseReportMode: false,
        ),
      );

      expect(first.response, isNull);
      expect(first.pendingInput, '\x1b[?1004\$');

      final second = buildTerminalWindowControlQueryResponses(
        input: 'pafter',
        pendingInput: first.pendingInput,
        metrics: null,
        modeState: const (
          reportFocusMode: true,
          bracketedPasteMode: false,
          colorSchemeUpdatesMode: false,
          isUsingAltBuffer: false,
          mouseTrackingMode: false,
          mouseDragTrackingMode: false,
          mouseMoveTrackingMode: false,
          sgrMouseReportMode: false,
        ),
      );

      expect(second.response, '\x1b[?1004;1\$y');
      expect(second.pendingInput, isEmpty);
    });

    test('extracts color scheme update mode changes', () {
      final enabled = extractTerminalControlModeUpdates(
        input: 'before\x1b[?2031hafter',
        pendingInput: '',
      );

      expect(enabled.colorSchemeUpdatesMode, isTrue);
      expect(enabled.pendingInput, isEmpty);

      final first = extractTerminalControlModeUpdates(
        input: 'before\x1b[?203',
        pendingInput: '',
      );

      expect(first.colorSchemeUpdatesMode, isNull);
      expect(first.pendingInput, '\x1b[?203');

      final disabled = extractTerminalControlModeUpdates(
        input: '1lafter',
        pendingInput: first.pendingInput,
      );

      expect(disabled.colorSchemeUpdatesMode, isFalse);
      expect(disabled.pendingInput, isEmpty);
    });

    test(
      'preserves split terminal theme mode report queries across chunks',
      () {
        final first = buildTerminalWindowControlQueryResponses(
          input: 'before\x1b[?99',
          pendingInput: '',
          metrics: null,
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
        );

        expect(first.response, isNull);
        expect(first.pendingInput, '\x1b[?99');

        final second = buildTerminalWindowControlQueryResponses(
          input: '6nafter',
          pendingInput: first.pendingInput,
          metrics: null,
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
        );

        expect(second.response, '\x1b[?997;2n');
        expect(second.pendingInput, isEmpty);
      },
    );
  });

  group('host key capture', () {
    test(
      'captures host key bytes from fragmented SSH identification and kex packets',
      () async {
        final expectedHostKey = _ed25519HostKeyBlob([1, 2, 3, 4]);
        final kexReplyPacket = _sshBinaryPacket(
          _sshMessageWithHostKey(31, expectedHostKey),
        );

        await expectLater(
          captureHostKeyFromHandshakeChunksForTesting(<Uint8List>[
            Uint8List.fromList(utf8.encode('SSH-2.0-test-server\r')),
            Uint8List.fromList(utf8.encode('\n')),
            Uint8List.sublistView(kexReplyPacket, 0, 3),
            Uint8List.sublistView(kexReplyPacket, 3, 9),
            Uint8List.sublistView(kexReplyPacket, 9),
          ]),
          completion(expectedHostKey),
        );
      },
    );

    test(
      'fails host key capture when the handshake packet is too large',
      () async {
        await expectLater(
          captureHostKeyFromHandshakeChunksForTesting(<Uint8List>[
            Uint8List.fromList(utf8.encode('SSH-2.0-test-server\r\n')),
            _oversizedPacketHeader(),
          ]),
          throwsA(
            isA<HostKeyVerificationException>().having(
              (error) => error.message,
              'message',
              contains('host-key capture limit'),
            ),
          ),
        );
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
                    'test-open-ssh-key-material\ntest\ntest-open-ssh-key-material-end',
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
        expect(config.privateKey, contains('test-open-ssh-key-material'));
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
    tearDown(resetQueuedSshExecsForTesting);

    test('forwards execute requests with an optional PTY config', () async {
      final client = _MockSshClient();
      final execSession = _MockExecSession();
      final session = SshSession(
        connectionId: 1,
        hostId: 2,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'tester',
        ),
      );

      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => execSession);

      final result = await session.execute(
        'tmux -CC attach-session -t test',
        pty: const SSHPtyConfig(width: 120, height: 30),
      );

      expect(result, same(execSession));
      verify(
        () => client.execute(
          'tmux -CC attach-session -t test',
          pty: const SSHPtyConfig(width: 120, height: 30),
        ),
      ).called(1);
    });

    test('runs queued exec work against the session connection', () async {
      final client = _MockSshClient();
      final session = SshSession(
        connectionId: 9,
        hostId: 2,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'tester',
        ),
      );
      final completers = List.generate(3, (_) => Completer<int>());
      final started = <int>[];
      final futures = [
        for (var index = 0; index < completers.length; index++)
          session.runQueuedExec(() {
            started.add(index);
            return completers[index].future;
          }),
      ];

      await pumpEventQueue();

      expect(started, [0, 1]);
      expect(activeQueuedSshExecCountForTesting(9), 2);
      expect(pendingQueuedSshExecCountForTesting(9), 1);

      for (var index = 0; index < completers.length; index++) {
        completers[index].complete(index);
      }

      expect(await Future.wait(futures), [0, 1, 2]);
    });

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

  group('SshSession terminal output batching', () {
    Future<
      ({
        Completer<void> done,
        _MockExecSession shell,
        SshSession session,
        StreamController<Uint8List> stderr,
        StreamController<Uint8List> stdout,
        List<List<int>> shellWrites,
      })
    >
    openShell() async {
      final client = _MockSshClient();
      final shell = _MockExecSession();
      final stdout = StreamController<Uint8List>();
      final stderr = StreamController<Uint8List>();
      final done = Completer<void>();
      final shellWrites = <List<int>>[];
      final session = SshSession(
        connectionId: 91,
        hostId: 2,
        client: client,
        config: const SshConnectionConfig(
          hostname: 'example.com',
          port: 22,
          username: 'tester',
        ),
      );

      when(
        () => client.shell(pty: any(named: 'pty')),
      ).thenAnswer((_) async => shell);
      when(() => shell.stdout).thenAnswer((_) => stdout.stream);
      when(() => shell.stderr).thenAnswer((_) => stderr.stream);
      when(() => shell.done).thenAnswer((_) => done.future);
      when(() => shell.write(any())).thenAnswer((invocation) {
        final bytes = invocation.positionalArguments.single as List<int>;
        shellWrites.add(List<int>.from(bytes));
      });

      await session.getShell();
      addTearDown(() async {
        await session.closeShell(waitForStreams: false);
        await stdout.close();
        await stderr.close();
        if (!done.isCompleted) {
          done.complete();
        }
      });
      return (
        done: done,
        shell: shell,
        session: session,
        stderr: stderr,
        stdout: stdout,
        shellWrites: shellWrites,
      );
    }

    String firstLineText(Terminal terminal) => terminal.buffer.lines[0]
        .getText(0, terminal.buffer.viewWidth)
        .trimRight();

    test('coalesces burst stdout into one terminal write per frame', () async {
      final shell = await openShell();
      final session = shell.session;
      final terminal = session.terminal!;
      final stdoutEvents = <String>[];
      final stdoutSubscription = session.shellStdoutStream.listen(
        stdoutEvents.add,
      );
      addTearDown(stdoutSubscription.cancel);

      var terminalNotifications = 0;
      terminal.addListener(() => terminalNotifications += 1);

      shell.stdout
        ..add(Uint8List.fromList(utf8.encode('hello ')))
        ..add(Uint8List.fromList(utf8.encode('world')));
      await pumpEventQueue();

      expect(firstLineText(terminal), isNot(contains('hello')));
      expect(stdoutEvents, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(firstLineText(terminal), 'hello world');
      expect(stdoutEvents, ['hello world']);
      expect(terminalNotifications, 1);
    });

    test('flushes terminal theme OSC queries without frame delay', () async {
      final shell = await openShell();
      final session = shell.session;
      final terminal = session.terminal!;
      session.terminalTheme = monkey_themes.TerminalThemes.defaultLightTheme;

      shell.stdout.add(Uint8List.fromList(utf8.encode('\x1b]11;?\x1b\\')));
      await pumpEventQueue();

      expect(firstLineText(terminal), isEmpty);
      expect(
        utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
        buildTerminalThemeOscResponse(
          theme: monkey_themes.TerminalThemes.defaultLightTheme,
          code: '11',
          args: const ['?'],
        ),
      );
    });

    test(
      'flushes tmux-wrapped terminal theme OSC queries without frame delay',
      () async {
        final shell = await openShell();
        final session = shell.session;
        final terminal = session.terminal!;
        session.terminalTheme = monkey_themes.TerminalThemes.defaultLightTheme;

        shell.stdout.add(
          Uint8List.fromList(
            utf8.encode('\x1bPtmux;\x1b\x1b]11;?\x1b\x1b\\\x1b\\'),
          ),
        );
        await pumpEventQueue();

        expect(firstLineText(terminal), isEmpty);
        expect(
          utf8.decode(shell.shellWrites.expand((chunk) => chunk).toList()),
          buildTerminalThemeOscResponse(
            theme: monkey_themes.TerminalThemes.defaultLightTheme,
            code: '11',
            args: const ['?'],
          ),
        );
      },
    );

    test('flushes pending terminal output before shell done event', () async {
      final shell = await openShell();
      final done = shell.done;
      final session = shell.session;
      final terminal = session.terminal!;
      final lineWhenDone = Completer<String>();
      final doneSubscription = session.shellDoneStream.listen((_) {
        lineWhenDone.complete(firstLineText(terminal));
      });
      addTearDown(doneSubscription.cancel);

      shell.stdout.add(Uint8List.fromList(utf8.encode('final prompt')));
      done.complete();

      expect(await lineWhenDone.future, 'final prompt');
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

    test('removes sessions that close unexpectedly', () async {
      final notifier = container.read(activeSessionsProvider.notifier);

      final result = await notifier.connect(42, forceNew: true);
      expect(result.success, isTrue);
      expect(result.connectionId, isNotNull);

      final connectionId = result.connectionId!;
      fakeSshService.completeConnection(connectionId);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(notifier.getSession(connectionId), isNull);
      expect(container.read(activeSessionsProvider)[connectionId], isNull);
      expect(
        notifier.getConnectionAttempt(42)?.latestMessage,
        'Connection closed',
      );
    });

    test('updateSessionTheme skips unchanged theme IDs', () async {
      final notifier = container.read(activeSessionsProvider.notifier);
      final notifications = <Map<int, SshConnectionState>>[];
      final subscription = container.listen<Map<int, SshConnectionState>>(
        activeSessionsProvider,
        (_, next) => notifications.add(next),
      );
      addTearDown(subscription.close);

      final result = await notifier.connect(42, forceNew: true);
      expect(result.success, isTrue);
      final connectionId = result.connectionId!;
      notifications.clear();

      notifier.updateSessionTheme(
        connectionId,
        monkey_themes.TerminalThemes.dracula.id,
        isDark: true,
      );
      expect(notifications, hasLength(1));
      notifications.clear();

      notifier.updateSessionTheme(
        connectionId,
        monkey_themes.TerminalThemes.dracula.id,
        isDark: true,
      );
      expect(notifications, isEmpty);
    });

    test(
      'disconnectAll clears active sessions and connection attempts',
      () async {
        final notifier = container.read(activeSessionsProvider.notifier);

        final result = await notifier.connect(42, forceNew: true);
        expect(result.success, isTrue);
        expect(notifier.getConnectionAttempt(42), isNotNull);

        await notifier.disconnectAll();

        expect(notifier.getActiveConnections(), isEmpty);
        expect(notifier.getConnectionAttempt(42), isNull);
        expect(container.read(activeSessionsProvider), isEmpty);
      },
    );
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
          privateKey: 'key-material-1',
        ),
      );
      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Auto Key 2',
          keyType: 'rsa',
          publicKey: 'ssh-rsa BBBB...',
          privateKey: 'key-material-2',
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
            privateKey: 'key-material-$i',
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
            privateKey: 'key-material-1',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key 2',
            keyType: 'rsa',
            publicKey: 'ssh-rsa BBBB...',
            privateKey: 'key-material-2',
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
          privateKey: 'selected-key-material',
        ),
      );
      await keyRepo.insert(
        SshKeysCompanion.insert(
          name: 'Other Key',
          keyType: 'rsa',
          publicKey: 'ssh-rsa DDDD...',
          privateKey: 'other-key-material',
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
      expect(config!.privateKey, 'selected-key-material');
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
            privateKey: 'selected-key-material',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key',
            keyType: 'rsa',
            publicKey: 'ssh-rsa DDDD...',
            privateKey: 'auto-key-material',
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
            privateKey: 'selected-jump-key-material',
          ),
        );
        await keyRepo.insert(
          SshKeysCompanion.insert(
            name: 'Auto Key',
            keyType: 'rsa',
            publicKey: 'ssh-rsa FFFF...',
            privateKey: 'auto-key-material',
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
          privateKey: 'unused-key-material',
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

    test(
      'connect prompts for unknown host before auth client creation',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final knownHostsRepository = KnownHostsRepository(db);
        final hostKeyBytes = _ed25519HostKeyBlob([1, 2, 3]);
        final sockets = [
          _FakeHostKeySocket(hostKeyBytes),
          _FakeHostKeySocket(hostKeyBytes),
        ];
        final client = _MockSshClient();
        var socketIndex = 0;
        var promptCount = 0;
        var clientFactoryCalls = 0;

        when(client.close).thenReturn(null);

        final service = SshService(
          knownHostsRepository: knownHostsRepository,
          hostKeyPromptHandler: (request) async {
            promptCount++;
            expect(request.isReplacement, isFalse);
            expect(clientFactoryCalls, 0);
            return HostKeyTrustDecision.trust;
          },
          socketConnector: (host, port, {timeout}) async {
            expect(host, 'new.example.com');
            expect(port, 22);
            return sockets[socketIndex++];
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
                clientFactoryCalls++;
                when(() => client.authenticated).thenAnswer((_) async {
                  final bytes = await (socket as HostKeySource).hostKeyBytes;
                  final trusted = await onVerifyHostKey!(
                    'ssh-ed25519',
                    Uint8List.fromList(md5.convert(bytes).bytes),
                  );
                  expect(trusted, isTrue);
                });
                return client;
              },
        );

        const config = SshConnectionConfig(
          hostname: 'new.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config);

        expect(result.success, isTrue);
        expect(socketIndex, 2);
        expect(promptCount, 1);
        expect(clientFactoryCalls, 1);
        expect(
          await knownHostsRepository.getByHost('new.example.com', 22),
          isNotNull,
        );
      },
    );

    test('connect rejects unknown host without starting auth', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final socket = _FakeHostKeySocket(_ed25519HostKeyBlob([1, 2, 3]));
      var clientFactoryCalls = 0;

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async => HostKeyTrustDecision.reject,
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
              clientFactoryCalls++;
              return _MockSshClient();
            },
      );

      const config = SshConnectionConfig(
        hostname: 'reject.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await service.connect(config);

      expect(result.success, isFalse);
      expect(result.error, contains('not trusted yet'));
      expect(clientFactoryCalls, 0);
      expect(
        await knownHostsRepository.getByHost('reject.example.com', 22),
        isNull,
      );
    });

    test('connect accepts pretrusted host without prompting', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final hostKeyBytes = _ed25519HostKeyBlob([4, 5, 6]);
      final trustedHostKey = VerifiedHostKey(
        hostname: 'trusted.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        hostKeyBytes: hostKeyBytes,
      );
      await knownHostsRepository.upsertTrustedHost(
        hostname: trustedHostKey.hostname,
        port: trustedHostKey.port,
        keyType: trustedHostKey.trustedKeyType,
        fingerprint: trustedHostKey.fingerprint,
        encodedHostKey: trustedHostKey.encodedHostKey,
        resetFirstSeen: true,
      );
      final sockets = [_FakeHostKeySocket(hostKeyBytes)];
      final client = _MockSshClient();
      var socketIndex = 0;
      var promptCount = 0;
      var clientFactoryCalls = 0;

      when(client.close).thenReturn(null);

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async {
          promptCount++;
          return HostKeyTrustDecision.reject;
        },
        socketConnector: (host, port, {timeout}) async =>
            sockets[socketIndex++],
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              identities,
              keepAliveInterval,
            }) {
              clientFactoryCalls++;
              when(() => client.authenticated).thenAnswer((_) async {
                final bytes = await (socket as HostKeySource).hostKeyBytes;
                final trusted = await onVerifyHostKey!(
                  'ssh-ed25519',
                  Uint8List.fromList(md5.convert(bytes).bytes),
                );
                expect(trusted, isTrue);
              });
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'trusted.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await service.connect(config);

      expect(result.success, isTrue);
      expect(socketIndex, 1);
      expect(clientFactoryCalls, 1);
      expect(promptCount, 0);
    });

    test('connect replaces a changed trusted host key after prompt', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final originalHostKey = VerifiedHostKey(
        hostname: 'replace-success.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        hostKeyBytes: _ed25519HostKeyBlob([1, 2, 3]),
      );
      final changedHostKeyBytes = _ed25519HostKeyBlob([7, 8, 9]);
      final changedHostKey = VerifiedHostKey(
        hostname: 'replace-success.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        hostKeyBytes: changedHostKeyBytes,
      );
      await knownHostsRepository.upsertTrustedHost(
        hostname: originalHostKey.hostname,
        port: originalHostKey.port,
        keyType: originalHostKey.trustedKeyType,
        fingerprint: originalHostKey.fingerprint,
        encodedHostKey: originalHostKey.encodedHostKey,
        resetFirstSeen: true,
      );
      final sockets = [
        _FakeHostKeySocket(changedHostKeyBytes),
        _FakeHostKeySocket(changedHostKeyBytes),
      ];
      final firstClient = _MockSshClient();
      final retryClient = _MockSshClient();
      var socketIndex = 0;
      var clientIndex = 0;
      var promptCount = 0;

      when(firstClient.close).thenReturn(null);
      when(retryClient.close).thenReturn(null);

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (request) async {
          promptCount++;
          expect(request.isReplacement, isTrue);
          expect(request.existingKnownHost, isNotNull);
          return HostKeyTrustDecision.replace;
        },
        socketConnector: (host, port, {timeout}) async =>
            sockets[socketIndex++],
        clientFactory:
            (
              socket, {
              required username,
              onVerifyHostKey,
              onPasswordRequest,
              identities,
              keepAliveInterval,
            }) {
              final client = clientIndex == 0 ? firstClient : retryClient;
              clientIndex++;
              when(() => client.authenticated).thenAnswer((_) async {
                final bytes = await (socket as HostKeySource).hostKeyBytes;
                final trusted = await onVerifyHostKey!(
                  'ssh-ed25519',
                  Uint8List.fromList(md5.convert(bytes).bytes),
                );
                if (!trusted) {
                  return Future<void>.error(
                    SSHHostkeyError('Hostkey verification failed'),
                  );
                }
              });
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'replace-success.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await service.connect(config);

      expect(result.success, isTrue);
      expect(socketIndex, 2);
      expect(clientIndex, 2);
      expect(promptCount, 1);
      final storedHost = await knownHostsRepository.getByHost(
        'replace-success.example.com',
        22,
      );
      expect(storedHost, isNotNull);
      expect(storedHost!.hostKey, changedHostKey.encodedHostKey);
      expect(storedHost.fingerprint, changedHostKey.fingerprint);
    });

    test(
      'connect rejects a changed trusted host key without retrying',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final knownHostsRepository = KnownHostsRepository(db);
        final originalHostKey = VerifiedHostKey(
          hostname: 'replace-reject.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          hostKeyBytes: _ed25519HostKeyBlob([1, 2, 3]),
        );
        final changedHostKeyBytes = _ed25519HostKeyBlob([7, 8, 9]);
        await knownHostsRepository.upsertTrustedHost(
          hostname: originalHostKey.hostname,
          port: originalHostKey.port,
          keyType: originalHostKey.trustedKeyType,
          fingerprint: originalHostKey.fingerprint,
          encodedHostKey: originalHostKey.encodedHostKey,
          resetFirstSeen: true,
        );
        final socket = _FakeHostKeySocket(changedHostKeyBytes);
        final client = _MockSshClient();
        var socketCount = 0;
        var clientFactoryCalls = 0;
        var promptCount = 0;

        when(client.close).thenReturn(null);

        final service = SshService(
          knownHostsRepository: knownHostsRepository,
          hostKeyPromptHandler: (request) async {
            promptCount++;
            expect(request.isReplacement, isTrue);
            return HostKeyTrustDecision.reject;
          },
          socketConnector: (host, port, {timeout}) async {
            socketCount++;
            return socket;
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
                clientFactoryCalls++;
                when(() => client.authenticated).thenAnswer((_) async {
                  final bytes = await (socket as HostKeySource).hostKeyBytes;
                  final trusted = await onVerifyHostKey!(
                    'ssh-ed25519',
                    Uint8List.fromList(md5.convert(bytes).bytes),
                  );
                  if (!trusted) {
                    return Future<void>.error(
                      SSHHostkeyError('Hostkey verification failed'),
                    );
                  }
                });
                return client;
              },
        );

        const config = SshConnectionConfig(
          hostname: 'replace-reject.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config);

        expect(result.success, isFalse);
        expect(result.error, contains('changed'));
        expect(socketCount, 1);
        expect(clientFactoryCalls, 1);
        expect(promptCount, 1);
        final storedHost = await knownHostsRepository.getByHost(
          'replace-reject.example.com',
          22,
        );
        expect(storedHost, isNotNull);
        expect(storedHost!.hostKey, originalHostKey.encodedHostKey);
      },
    );

    test('connect fails if host key changes after trust prompt', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final probeHostKeyBytes = _ed25519HostKeyBlob([1, 2, 3]);
      final changedHostKeyBytes = _ed25519HostKeyBlob([7, 8, 9]);
      final sockets = [
        _FakeHostKeySocket(probeHostKeyBytes),
        _FakeHostKeySocket(changedHostKeyBytes),
      ];
      final client = _MockSshClient();
      var socketIndex = 0;

      when(client.close).thenReturn(null);

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async => HostKeyTrustDecision.trust,
        socketConnector: (host, port, {timeout}) async =>
            sockets[socketIndex++],
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
              });
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'race.example.com',
        port: 22,
        username: 'tester',
      );

      final result = await service.connect(config);

      expect(result.success, isFalse);
      expect(result.error, contains('changed between verification'));
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

    test('connect uses one connection per pretrusted jump-host hop', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final knownHostsRepository = KnownHostsRepository(db);
      final jumpHostKeyBytes = _ed25519HostKeyBlob([1, 2, 3]);
      final targetHostKeyBytes = _ed25519HostKeyBlob([4, 5, 6]);
      final jumpHostKey = VerifiedHostKey(
        hostname: 'jump-trusted.example.com',
        port: 2222,
        keyType: 'ssh-ed25519',
        hostKeyBytes: jumpHostKeyBytes,
      );
      final targetHostKey = VerifiedHostKey(
        hostname: 'target-trusted.example.com',
        port: 22,
        keyType: 'ssh-ed25519',
        hostKeyBytes: targetHostKeyBytes,
      );
      for (final hostKey in [jumpHostKey, targetHostKey]) {
        await knownHostsRepository.upsertTrustedHost(
          hostname: hostKey.hostname,
          port: hostKey.port,
          keyType: hostKey.trustedKeyType,
          fingerprint: hostKey.fingerprint,
          encodedHostKey: hostKey.encodedHostKey,
          resetFirstSeen: true,
        );
      }

      final jumpSocket = _FakeHostKeySocket(jumpHostKeyBytes);
      final targetSocket = _FakeForwardHostKeySocket(targetHostKeyBytes);
      final jumpClient = _MockSshClient();
      final targetClient = _MockSshClient();
      var socketConnectCount = 0;
      var forwardCount = 0;
      var clientIndex = 0;
      var promptCount = 0;

      when(
        () => jumpClient.forwardLocal('target-trusted.example.com', 22),
      ).thenAnswer((_) async {
        forwardCount++;
        return targetSocket;
      });
      when(jumpClient.close).thenReturn(null);
      when(targetClient.close).thenReturn(null);

      final service = SshService(
        knownHostsRepository: knownHostsRepository,
        hostKeyPromptHandler: (_) async {
          promptCount++;
          return HostKeyTrustDecision.reject;
        },
        socketConnector: (host, port, {timeout}) async {
          expect(host, 'jump-trusted.example.com');
          expect(port, 2222);
          socketConnectCount++;
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
              final hostKeyBytes = (socket as HostKeySource).hostKeyBytes;
              clientIndex++;
              when(() => client.authenticated).thenAnswer((_) async {
                final bytes = await hostKeyBytes;
                final trusted = await onVerifyHostKey!(
                  'ssh-ed25519',
                  Uint8List.fromList(md5.convert(bytes).bytes),
                );
                expect(trusted, isTrue);
              });
              return client;
            },
      );

      const config = SshConnectionConfig(
        hostname: 'target-trusted.example.com',
        port: 22,
        username: 'target',
        jumpHost: SshConnectionConfig(
          hostname: 'jump-trusted.example.com',
          port: 2222,
          username: 'jump',
        ),
      );

      final result = await service.connect(config);

      expect(result.success, isTrue);
      expect(socketConnectCount, 1);
      expect(forwardCount, 1);
      expect(clientIndex, 2);
      expect(promptCount, 0);
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

    test(
      'connect preserves an existing host key when replacement auth fails',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final knownHostsRepository = KnownHostsRepository(db);
        final originalHostKey = VerifiedHostKey(
          hostname: 'replace.example.com',
          port: 22,
          keyType: 'ssh-ed25519',
          hostKeyBytes: _ed25519HostKeyBlob([1, 2, 3]),
        );
        await knownHostsRepository.upsertTrustedHost(
          hostname: originalHostKey.hostname,
          port: originalHostKey.port,
          keyType: originalHostKey.trustedKeyType,
          fingerprint: originalHostKey.fingerprint,
          encodedHostKey: originalHostKey.encodedHostKey,
          resetFirstSeen: true,
        );

        final changedHostKeyBytes = _ed25519HostKeyBlob([7, 8, 9]);
        final sockets = [
          _FakeHostKeySocket(changedHostKeyBytes),
          _FakeHostKeySocket(changedHostKeyBytes),
        ];
        final firstClient = _MockSshClient();
        final retryClient = _MockSshClient();
        var socketIndex = 0;
        var clientIndex = 0;

        when(firstClient.close).thenReturn(null);
        when(retryClient.close).thenReturn(null);

        final service = SshService(
          knownHostsRepository: knownHostsRepository,
          hostKeyPromptHandler: (_) async => HostKeyTrustDecision.replace,
          socketConnector: (host, port, {timeout}) async =>
              sockets[socketIndex++],
          clientFactory:
              (
                socket, {
                required username,
                onVerifyHostKey,
                onPasswordRequest,
                identities,
                keepAliveInterval,
              }) {
                final client = clientIndex == 0 ? firstClient : retryClient;
                final shouldFailAuth = clientIndex == 1;
                clientIndex++;
                when(() => client.authenticated).thenAnswer((_) async {
                  final bytes = await (socket as HostKeySource).hostKeyBytes;
                  final trusted = await onVerifyHostKey!(
                    'ssh-ed25519',
                    Uint8List.fromList(md5.convert(bytes).bytes),
                  );
                  if (!trusted) {
                    return Future<void>.error(
                      SSHHostkeyError('Hostkey verification failed'),
                    );
                  }
                  if (shouldFailAuth) {
                    return Future<void>.error(
                      SSHAuthFailError('Authentication failed'),
                    );
                  }
                });
                return client;
              },
        );

        const config = SshConnectionConfig(
          hostname: 'replace.example.com',
          port: 22,
          username: 'tester',
        );

        final result = await service.connect(config);

        expect(result.success, isFalse);
        expect(socketIndex, 2);
        expect(clientIndex, 2);
        final storedHost = await knownHostsRepository.getByHost(
          'replace.example.com',
          22,
        );
        expect(storedHost, isNotNull);
        expect(storedHost!.hostKey, originalHostKey.encodedHostKey);
        expect(storedHost.fingerprint, originalHostKey.fingerprint);
      },
    );

    test('sessions map is unmodifiable', () {
      expect(
        () => (sshService.sessions as Map)[1] = 'test',
        throwsA(isA<Error>()),
      );
    });
  });

  group('connectToHost SSID-based jump host bypass', () {
    Future<int> seedHostWithJump(
      AppDatabase db, {
      String? skipJumpHostOnSsids,
    }) async {
      final jumpHostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Bastion',
              hostname: 'bastion.example.com',
              username: 'bastion',
            ),
          );
      return db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Target',
              hostname: 'target.example.com',
              username: 'target',
              jumpHostId: Value(jumpHostId),
              skipJumpHostOnSsids: Value(skipJumpHostOnSsids),
            ),
          );
    }

    test('uses jump host when no SSIDs are configured', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService('home');
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(db);
      await service.connectToHost(hostId);

      expect(service.capturedConfig?.jumpHost, isNotNull);
      expect(wifiNetworkService.requestPermissionCallCount, 0);
      expect(wifiNetworkService.getCurrentSsidCallCount, 0);
    });

    test('uses jump host when current SSID is not in skip list', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService('cafe');
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(
        db,
        skipJumpHostOnSsids: 'home\noffice',
      );
      await service.connectToHost(hostId);

      expect(service.capturedConfig?.jumpHost, isNotNull);
      expect(service.capturedConfig?.hostname, 'target.example.com');
      expect(wifiNetworkService.requestPermissionCallCount, 1);
      expect(wifiNetworkService.getCurrentSsidCallCount, 1);
    });

    test('skips jump host when current SSID is in skip list', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService('home');
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(
        db,
        skipJumpHostOnSsids: 'home\noffice',
      );
      await service.connectToHost(hostId);

      expect(service.capturedConfig, isNotNull);
      expect(service.capturedConfig!.jumpHost, isNull);
      expect(service.capturedConfig!.hostname, 'target.example.com');
      expect(wifiNetworkService.requestPermissionCallCount, 1);
      expect(wifiNetworkService.getCurrentSsidCallCount, 1);
    });

    test('uses jump host when Wi-Fi permission is denied', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService(
        'home',
        permissionStatus: WifiPermissionStatus.denied,
      );
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(db, skipJumpHostOnSsids: 'home');
      await service.connectToHost(hostId);

      expect(service.capturedConfig?.jumpHost, isNotNull);
      expect(wifiNetworkService.requestPermissionCallCount, 1);
      expect(wifiNetworkService.getCurrentSsidCallCount, 0);
    });

    test('uses jump host when SSID detection returns null', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryption = SecretEncryptionService.forTesting();
      final hostRepo = HostRepository(db, encryption);
      final keyRepo = KeyRepository(db, encryption);
      final wifiNetworkService = _StubWifiNetworkService(null);
      final service = _CapturingSshService(
        hostRepository: hostRepo,
        keyRepository: keyRepo,
        wifiNetworkService: wifiNetworkService,
      );

      final hostId = await seedHostWithJump(db, skipJumpHostOnSsids: 'home');
      await service.connectToHost(hostId);

      expect(service.capturedConfig?.jumpHost, isNotNull);
      expect(wifiNetworkService.requestPermissionCallCount, 1);
      expect(wifiNetworkService.getCurrentSsidCallCount, 1);
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

Uint8List _sshString(List<int> value) {
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(value.length))
    ..add(value);
  return writer.takeBytes();
}

Uint8List _sshMessageWithHostKey(int messageId, Uint8List hostKey) {
  final writer = BytesBuilder(copy: false)
    ..add([messageId])
    ..add(_sshString(hostKey))
    ..add(_sshString(const <int>[0, 1, 2, 3]))
    ..add(_sshString(const <int>[4, 5, 6, 7]));
  return writer.takeBytes();
}

Uint8List _sshBinaryPacket(Uint8List payload) {
  const paddingLength = 4;
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(payload.length + paddingLength + 1))
    ..add([paddingLength])
    ..add(payload)
    ..add(const <int>[0, 0, 0, 0]);
  return writer.takeBytes();
}

Uint8List _oversizedPacketHeader() =>
    Uint8List.fromList([0x00, 0x04, 0x00, 0x01, 0x04]);

Answer<Future<SSHForwardChannel>> _returnTargetSocket(
  SSHForwardChannel socket,
) =>
    (_) async => socket;
