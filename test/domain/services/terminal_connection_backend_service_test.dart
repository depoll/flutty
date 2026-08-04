import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_backend.dart';
import 'package:monkeyssh/domain/models/terminal_theme.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/remote_multiplexer_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/terminal_connection_backend_service.dart';

class _MockSshClient extends Mock implements SSHClient {}

class _MockSshExecSession extends Mock implements SSHSession {}

class _MockMonkeyMuxService extends Mock implements MonkeyMuxService {}

void main() {
  tearDown(resetQueuedSshExecsForTesting);

  group('TerminalConnectionBackendService', () {
    test('resolves direct backend when no multiplexer is active', () {
      final service = TerminalConnectionBackendService(
        tmuxMultiplexer: _FakeRemoteMultiplexerService(),
        monkeyMuxService: _MockMonkeyMuxService(),
      );

      final backend = service.resolve(_buildSession(_MockSshClient()));

      expect(backend.type, TerminalBackendType.direct);
      expect(backend.remoteMuxBackend, isNull);
      expect(backend.capabilities.supportsWindows, isFalse);
      expect(backend.capabilities.supportsClientCommands, isTrue);
    });

    test('runs direct client commands through the SSH exec queue', () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        commands.add(invocation.positionalArguments.single as String);
        return _buildExecSession(stdout: 'ok');
      });
      final service = TerminalConnectionBackendService(
        tmuxMultiplexer: _FakeRemoteMultiplexerService(),
        monkeyMuxService: _MockMonkeyMuxService(),
      );
      final backend = service.resolve(_buildSession(client));

      final result = await backend.runClientCommand(
        'printf hi',
        workingDirectory: "/tmp/user's repo",
      );

      expect(result.output, 'ok');
      expect(result.exitCode, isNull);
      expect(
        commands,
        contains("cd '/tmp/user'\"'\"'s repo' && ( printf hi )"),
      );
    });

    test('delegates tmux window operations through the multiplexer', () async {
      final tmuxMultiplexer = _FakeRemoteMultiplexerService(
        context: const TmuxPaneContext(
          currentPath: '/repo',
          currentCommand: 'zsh',
        ),
      );
      final service = TerminalConnectionBackendService(
        tmuxMultiplexer: tmuxMultiplexer,
        monkeyMuxService: _MockMonkeyMuxService(),
      );
      final session = _buildSession(_MockSshClient())
        ..remoteMuxBackend = RemoteMuxBackend.tmux
        ..remoteMuxSessionName = 'dev';

      final backend = service.resolve(session, tmuxExtraFlags: '-L flutty');
      final context = await backend.currentPaneContext();
      await backend.selectWindow(2, windowId: '@7');
      await backend.selectWindow(
        4,
        windowId: '@9',
        clientImageSignatures: const {1: 111, 2: 222},
      );
      await backend.createWindow(command: 'codex', workingDirectory: '/repo');
      await backend.killWindow(3);

      expect(backend.type, TerminalBackendType.tmux);
      expect(backend.capabilities.supportsWindows, isTrue);
      expect(context?.currentPath, '/repo');
      expect(
        tmuxMultiplexer.calls,
        containsAll(<String>[
          'context:dev:-L flutty',
          'select:dev:2:@7:-L flutty:null',
          'select:dev:4:@9:-L flutty:2',
          'create:dev:codex:/repo:-L flutty',
          'kill:dev:3:-L flutty',
        ]),
      );
    });

    test(
      'runs MonkeyMux client commands through the control channel',
      () async {
        final monkeyMuxService = _MockMonkeyMuxService();
        final session = _buildSession(_MockSshClient())
          ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
          ..remoteMuxSessionName = 'dev';
        when(
          () => monkeyMuxService.runClientCommand(
            session,
            'dev',
            'printf hi',
            priority: SshExecPriority.low,
          ),
        ).thenAnswer(
          (_) async =>
              const TerminalClientCommandResult(output: 'ok', exitCode: 0),
        );
        final service = TerminalConnectionBackendService(
          tmuxMultiplexer: _FakeRemoteMultiplexerService(),
          monkeyMuxService: monkeyMuxService,
        );

        final result = await service
            .resolve(session)
            .runClientCommand('printf hi', priority: SshExecPriority.low);

        expect(result.output, 'ok');
        expect(result.exitCode, 0);
        verify(
          () => monkeyMuxService.runClientCommand(
            session,
            'dev',
            'printf hi',
            priority: SshExecPriority.low,
          ),
        ).called(1);
      },
    );
  });
}

SshSession _buildSession(SSHClient client) => SshSession(
  connectionId: 42,
  hostId: 7,
  client: client,
  config: const SshConnectionConfig(
    hostname: 'example.com',
    port: 22,
    username: 'tester',
  ),
);

SSHSession _buildExecSession({String stdout = '', String stderr = ''}) {
  final exec = _MockSshExecSession();
  when(() => exec.stdout).thenAnswer(
    (_) => Stream<Uint8List>.fromIterable([
      Uint8List.fromList(utf8.encode(stdout)),
    ]),
  );
  when(() => exec.stderr).thenAnswer(
    (_) => Stream<Uint8List>.fromIterable([
      Uint8List.fromList(utf8.encode(stderr)),
    ]),
  );
  when(() => exec.done).thenAnswer((_) => Future<void>.value());
  return exec;
}

class _FakeRemoteMultiplexerService implements RemoteMultiplexerService {
  _FakeRemoteMultiplexerService({this.context});

  final TmuxPaneContext? context;
  final List<String> calls = <String>[];

  @override
  Future<String?> detectedVersion(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async => null;

  @override
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async => const <TmuxWindow>[];

  @override
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) => const Stream<TmuxWindowChangeEvent>.empty();

  @override
  Future<TmuxPaneContext?> currentPaneContext(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) async {
    calls.add('context:$sessionName:$extraFlags');
    return context;
  }

  @override
  Future<String?> currentPanePath(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) async {
    calls.add('path:$sessionName:$extraFlags');
    return context?.currentPath;
  }

  @override
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
    String? workingDirectory,
    String? extraFlags,
  }) async {
    calls.add('create:$sessionName:$command:$workingDirectory:$extraFlags');
  }

  @override
  Future<void> selectWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
    Map<int, int>? clientImageSignatures,
  }) async {
    calls.add(
      'select:$sessionName:$windowIndex:$windowId:$extraFlags:'
      '${clientImageSignatures == null ? 'null' : clientImageSignatures.length}',
    );
  }

  @override
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? extraFlags,
  }) async {
    calls.add('kill:$sessionName:$windowIndex:$extraFlags');
  }

  @override
  bool isExecChannelCoolingDown(SshSession session) => false;

  @override
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async => true;

  @override
  Future<String?> foregroundSessionNameOrThrow(
    SshSession session, {
    String? extraFlags,
  }) async => null;

  @override
  Future<void> refreshTerminalTheme(
    SshSession session,
    String sessionName,
    TerminalThemeData theme, {
    String? extraFlags,
    bool forceForegroundRedraw = false,
  }) async {
    calls.add('theme:$sessionName:$extraFlags:$forceForegroundRedraw');
  }
}
