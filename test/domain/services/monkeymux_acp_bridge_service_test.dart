import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// ignore_for_file: public_member_api_docs

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/monkeymux_acp_bridge.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/terminal_backend.dart';
import 'package:monkeyssh/domain/services/monkeymux_acp_bridge_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';
import 'package:monkeyssh/domain/services/ssh_exec_queue.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

const _bridgeId = '0123456789abcdef0123456789abcdef';
const _otherBridgeId = 'fedcba9876543210fedcba9876543210';
const _commandHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class _MockSshClient extends Mock implements SSHClient {}

class _MockSshChannel extends Mock implements SSHSession {}

class _MockMonkeyMuxService extends Mock implements MonkeyMuxService {}

final class _FakeInstaller extends MonkeyMuxInstallerService {
  _FakeInstaller(this.installation)
    : super(
        manifestFuture: Future.value(
          const MonkeyMuxManifest(version: 'test', entries: []),
        ),
        remoteFileService: const RemoteFileService(),
      );

  final MonkeyMuxInstallation installation;
  int ensureCount = 0;
  MonkeyMuxInstallConfirmation? lastConfirmInstall;
  SshExecPriority? lastPriority;

  @override
  Future<MonkeyMuxInstallation> ensureInstalled(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.low,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    ensureCount += 1;
    lastConfirmInstall = confirmInstall;
    lastPriority = priority;
    return installation;
  }
}

final class _TestChannel {
  _TestChannel({this.onWrite}) {
    when(() => session.stdout).thenAnswer((_) => stdout.stream);
    when(() => session.stderr).thenAnswer((_) => stderr.stream);
    when(() => session.write(any())).thenAnswer((invocation) {
      final bytes = invocation.positionalArguments.single as Uint8List;
      writes.add(List<int>.of(bytes));
      onWrite?.call(utf8.decode(bytes));
    });
    when(session.close).thenAnswer((_) {
      localCloseCount += 1;
    });
  }

  final session = _MockSshChannel();
  final stdout = StreamController<Uint8List>();
  final stderr = StreamController<Uint8List>();
  final List<List<int>> writes = [];
  final void Function(String value)? onWrite;
  int localCloseCount = 0;

  void addText(String value) {
    stdout.add(Uint8List.fromList(utf8.encode(value)));
  }

  void addSplitText(String value, List<int> splitOffsets) {
    final bytes = utf8.encode(value);
    var start = 0;
    for (final end in [...splitOffsets, bytes.length]) {
      stdout.add(Uint8List.fromList(bytes.sublist(start, end)));
      start = end;
    }
  }

  Future<void> remoteClose() async {
    await stdout.close();
    await stderr.close();
  }
}

SshSession _sshSession(
  SSHClient client, {
  int connectionId = 1,
  bool windows = false,
}) {
  if (windows) {
    when(
      () => client.remoteVersion,
    ).thenReturn('SSH-2.0-OpenSSH_for_Windows_9.5');
  } else {
    when(() => client.remoteVersion).thenReturn('SSH-2.0-OpenSSH_9.9');
  }
  return SshSession(
    connectionId: connectionId,
    hostId: 7,
    client: client,
    config: const SshConnectionConfig(
      hostname: 'example.com',
      port: 22,
      username: 'demo',
    ),
  );
}

Map<String, Object?> _metadata({
  String id = _bridgeId,
  String state = 'running',
  int nextSequence = 0,
  int pendingRequestCount = 1,
}) => {
  'id': id,
  'providerId': 'builtin:copilot-cli',
  'sessionId': 'session-1',
  'cwd': '/home/demo/project with spaces',
  'provider': 'Copilot CLI',
  'commandHash': _commandHash,
  'state': state,
  'clientCount': 1,
  'pendingRequestCount': pendingRequestCount,
  'inFlightTurnCount': 0,
  'lastActivityUnix': 1700000000,
  'startedAtUnix': 1699999990,
  'nextSequence': nextSequence,
};

String _frame(Map<String, Object?> message) => '${jsonEncode(message)}\n';

Map<String, Object?> _decodeFrame(List<int> bytes) =>
    (jsonDecode(utf8.decode(bytes).trim()) as Map).map(
      (key, value) => MapEntry(key.toString(), value),
    );

String _decodePowerShellScript(String command) {
  const marker = '-EncodedCommand ';
  final encoded = command.substring(command.indexOf(marker) + marker.length);
  final bytes = base64.decode(encoded.trim());
  final units = <int>[];
  for (var index = 0; index + 1 < bytes.length; index += 2) {
    units.add(bytes[index] | (bytes[index + 1] << 8));
  }
  return String.fromCharCodes(units);
}

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(() {
    registerFallbackValue(Uint8List(0));
    registerFallbackValue(SshExecPriority.normal);
  });

  test('quotes exact provider argv on POSIX and Windows', () {
    final posix = buildMonkeyMuxAcpProviderCommand(const [
      'copilot',
      '--acp',
      "quote'value",
      'space value',
    ], isWindows: false);
    expect(posix, contains('. ~/.zprofile'));
    expect(posix, contains('. ~/.zshrc'));
    expect(posix, contains('. ~/.bashrc'));
    expect(posix, contains(r'$HOME/.opencode/bin'));
    expect(posix, contains(r'$HOME/.local/bin'));
    expect(
      posix,
      endsWith("exec 'copilot' '--acp' 'quote'\"'\"'value' 'space value'"),
    );

    final windows = buildMonkeyMuxAcpProviderCommand(const [
      r'C:\Program Files\Copilot\copilot.exe',
      '--acp',
      "a'b",
      'x y',
    ], isWindows: true);
    final script = _decodePowerShellScript(windows);
    expect(
      script,
      contains(r"$__flAcpExe='C:\Program Files\Copilot\copilot.exe'"),
    );
    expect(script, contains(r"$__flAcpArgs=@('--acp','a''b','x y')"));
    expect(script, contains(r'& $__flAcpExe @__flAcpArgs'));
  });

  test('Cursor ACP leaves credential handling to Cursor', () {
    final cursor = buildMonkeyMuxAcpProviderCommand(const [
      '/Users/demo/.local/bin/cursor-agent',
      'acp',
    ], isWindows: false);
    expect(cursor, isNot(contains('AGENT_CLI_CREDENTIAL_STORE')));
    expect(cursor, isNot(contains('cursor-access-token')));
    expect(cursor, isNot(contains('CURSOR_API_KEY')));
    expect(cursor, isNot(contains('security find-generic-password')));
    expect(
      cursor,
      contains("exec '/Users/demo/.local/bin/cursor-agent' 'acp'"),
    );
  });

  test(
    'starts every ACP provider through the active MonkeyMux server context',
    () async {
      final client = _MockSshClient();
      final session = _sshSession(client)
        ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
        ..remoteMuxSessionName = 'work';
      final mux = _MockMonkeyMuxService();
      when(
        () => mux.startAcpBridge(
          session,
          'work',
          providerId: any(named: 'providerId'),
          provider: any(named: 'provider'),
          command: any(named: 'command'),
          cwd: any(named: 'cwd'),
          priority: any(named: 'priority'),
        ),
      ).thenAnswer(
        (_) async => TerminalClientCommandResult(
          output: _frame({
            'version': 1,
            'type': 'started',
            'bridgeId': _bridgeId,
            'windowId': '@7',
          }),
        ),
      );
      final service = MonkeyMuxAcpBridgeService(
        installer: _FakeInstaller(
          const MonkeyMuxInstallation(
            executablePath: '/home/demo/.monkeyssh/monkeymux',
            platform: 'darwin-arm64',
            version: 'test',
          ),
        ),
        monkeyMuxService: mux,
      );
      const launches = [
        (
          providerId: 'builtin:cursor-agent-acp',
          label: 'Cursor Agent',
          argv: ['/Users/demo/.local/bin/cursor-agent', 'acp'],
          executable: '/Users/demo/.local/bin/cursor-agent',
        ),
        (
          providerId: 'builtin:claude-agent-acp',
          label: 'Claude Agent',
          argv: [
            'npx',
            '--yes',
            '@agentclientprotocol/claude-agent-acp@0.70.0',
          ],
          executable: 'npx',
        ),
        (
          providerId: 'builtin:opencode',
          label: 'OpenCode',
          argv: ['opencode', 'acp'],
          executable: 'opencode',
        ),
        (
          providerId: 'builtin:hermes-acp',
          label: 'Hermes',
          argv: ['hermes', '--profile', 'work', 'acp'],
          executable: 'hermes',
        ),
        (
          providerId: 'builtin:openclaw-acp',
          label: 'OpenClaw',
          argv: ['openclaw', '--profile', 'ops', 'acp'],
          executable: 'openclaw',
        ),
        (
          providerId: 'custom:test-provider',
          label: 'Custom provider',
          argv: ['/opt/tools/custom-acp', '--stdio'],
          executable: '/opt/tools/custom-acp',
        ),
      ];

      for (final launch in launches) {
        final result = await service.start(
          session: session,
          providerId: launch.providerId,
          providerLabel: launch.label,
          launchArgv: launch.argv,
          cwd: '/home/demo/project',
        );
        expect(result.bridgeId, _bridgeId);
        expect(result.windowId, '@7');
      }

      for (final launch in launches) {
        final command =
            verify(
                  () => mux.startAcpBridge(
                    session,
                    'work',
                    providerId: launch.providerId,
                    provider: launch.label,
                    command: captureAny(named: 'command'),
                    cwd: '/home/demo/project',
                    priority: any(named: 'priority'),
                  ),
                ).captured.single
                as String;
        expect(command, contains('exec'));
        expect(command, contains(launch.executable));
      }
      verifyNever(
        () => mux.runClientCommand(
          session,
          any(),
          any(),
          priority: any(named: 'priority'),
        ),
      );
      verifyNever(() => client.execute(any(), pty: any(named: 'pty')));
    },
  );

  test('maps Cursor keychain lock from active MonkeyMux server', () async {
    final client = _MockSshClient();
    final session = _sshSession(client)
      ..remoteMuxBackend = RemoteMuxBackend.monkeyMux
      ..remoteMuxSessionName = 'work';
    final mux = _MockMonkeyMuxService();
    when(
      () => mux.startAcpBridge(
        session,
        'work',
        providerId: any(named: 'providerId'),
        provider: any(named: 'provider'),
        command: any(named: 'command'),
        cwd: any(named: 'cwd'),
        priority: any(named: 'priority'),
      ),
    ).thenThrow(
      const MonkeyMuxInstallException('Cursor Agent login keychain is locked'),
    );
    final service = MonkeyMuxAcpBridgeService(
      installer: _FakeInstaller(
        const MonkeyMuxInstallation(
          executablePath: '/home/demo/.monkeyssh/monkeymux',
          platform: 'darwin-arm64',
          version: 'test',
        ),
      ),
      monkeyMuxService: mux,
    );

    await expectLater(
      service.start(
        session: session,
        providerId: 'builtin:cursor-agent-acp',
        providerLabel: 'Cursor Agent',
        launchArgv: const ['cursor-agent', 'acp'],
        cwd: '/home/demo/project',
      ),
      throwsA(
        isA<MonkeyMuxAcpBridgeException>().having(
          (error) => error.kind,
          'kind',
          MonkeyMuxAcpBridgeErrorKind.keychainLocked,
        ),
      ),
    );
  });

  test('probes adapters through interactive POSIX and Windows profiles', () {
    final posix = buildMonkeyMuxAcpExecutableProbeCommand(const {
      'npx',
      'claude-agent-acp',
    });
    expect(posix, contains(r'SH="${SHELL:-/bin/sh}"'));
    expect(posix, contains(r'"$SH" -ic'));
    expect(posix, contains('claude-agent-acp npx'));
    expect(posix, contains('. ~/.zshrc'));

    final windows = buildMonkeyMuxAcpWindowsExecutableProbeScript(const {
      'npx',
      'claude-agent-acp',
    });
    expect(windows, contains(powerShellProfilePathPreamble));
    expect(windows, contains("'claude-agent-acp','npx'"));
    expect(windows, contains('-CommandType Application,ExternalScript'));
  });

  test('parses adapter probe output through the requested allowlist', () {
    expect(
      parseMonkeyMuxAcpExecutableProbeOutput(
        'profile chatter\n'
        'claude-agent-acp\u001f/Users/demo/bin/claude-agent-acp\n'
        'npx\u001f/opt/homebrew/bin/npx\n'
        'npx\u001fnpx\n'
        'unrequested\u001f/usr/bin/unrequested\n',
        const {'claude-agent-acp', 'npx'},
      ),
      {
        'claude-agent-acp': '/Users/demo/bin/claude-agent-acp',
        'npx': '/opt/homebrew/bin/npx',
      },
    );
    expect(
      () => buildMonkeyMuxAcpExecutableProbeCommand(const {'npx; unsafe'}),
      throwsArgumentError,
    );
  });

  test('starts, lists, statuses, and stops bridges on POSIX', () async {
    final client = _MockSshClient();
    final commands = <String>[];
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      invocation,
    ) async {
      final command = invocation.positionalArguments.single as String;
      commands.add(command);
      final channel = _TestChannel();
      scheduleMicrotask(() async {
        if (command.contains("'start'")) {
          channel.addSplitText(
            _frame({'version': 1, 'type': 'started', 'bridgeId': _bridgeId}),
            [5, 17],
          );
        } else if (command.contains("'list'")) {
          channel.addText(
            _frame({
              'version': 1,
              'type': 'list',
              'bridges': [_metadata()],
            }),
          );
        } else if (command.contains("'status'")) {
          channel.addText(
            _frame({
              'version': 1,
              'type': 'status',
              'bridgeId': _bridgeId,
              'bridge': _metadata(),
            }),
          );
        } else if (command.contains("'stop'")) {
          channel.addText(
            _frame({'version': 1, 'type': 'stopping', 'bridgeId': _bridgeId}),
          );
        }
        await channel.remoteClose();
      });
      return channel.session;
    });
    final session = _sshSession(client);
    final installer = _FakeInstaller(
      const MonkeyMuxInstallation(
        executablePath: '/home/demo/.monkeyssh/monkeymux',
        platform: 'linux-amd64',
        version: 'test',
      ),
    );
    final service = MonkeyMuxAcpBridgeService(installer: installer);

    final started = await service.start(
      session: session,
      providerId: 'copilot',
      providerLabel: "Copilot's CLI",
      launchArgv: const ['copilot', '--acp'],
      cwd: '/home/demo/project with spaces',
    );
    Future<bool> confirmInstall(MonkeyMuxInstallRequest _) async => true;
    final bridges = await service.list(session, confirmInstall: confirmInstall);
    expect(installer.lastConfirmInstall, same(confirmInstall));
    expect(installer.lastPriority, SshExecPriority.normal);
    final status = await service.status(session, _bridgeId);
    await service.stop(session, _bridgeId);

    expect(started.bridgeId, _bridgeId);
    expect(bridges.single.id, _bridgeId);
    expect(bridges.single.providerId, 'builtin:copilot-cli');
    expect(bridges.single.sessionId, 'session-1');
    expect(bridges.single.cwd, '/home/demo/project with spaces');
    expect(status.state, MonkeyMuxAcpProviderState.running);
    expect(commands, hasLength(4));
    expect(commands.first, contains("'Copilot'\"'\"'s CLI'"));
    expect(commands.first, contains("'/home/demo/project with spaces'"));
  });

  test(
    'uses encoded PowerShell for Windows helper lifecycle commands',
    () async {
      final client = _MockSshClient();
      final commands = <String>[];
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        invocation,
      ) async {
        final command = invocation.positionalArguments.single as String;
        commands.add(command);
        final script = _decodePowerShellScript(command);
        final channel = _TestChannel();
        scheduleMicrotask(() async {
          if (script.contains("'start'")) {
            channel.addText(
              _frame({'version': 1, 'type': 'started', 'bridgeId': _bridgeId}),
            );
          } else if (script.contains("'list'")) {
            channel.addText(
              _frame({
                'version': 1,
                'type': 'list',
                'bridges': [_metadata()],
              }),
            );
          } else if (script.contains("'status'")) {
            channel.addText(
              _frame({
                'version': 1,
                'type': 'status',
                'bridgeId': _bridgeId,
                'bridge': _metadata(),
              }),
            );
          } else if (script.contains("'stop'")) {
            channel.addText(
              _frame({'version': 1, 'type': 'stopping', 'bridgeId': _bridgeId}),
            );
          }
          await channel.remoteClose();
        });
        return channel.session;
      });
      final service = MonkeyMuxAcpBridgeService(
        installer: _FakeInstaller(
          const MonkeyMuxInstallation(
            executablePath: r'C:\Users\demo\.monkeyssh\monkeymux.exe',
            platform: 'windows-amd64',
            version: 'test',
          ),
        ),
      );
      final session = _sshSession(client, windows: true);

      final started = await service.start(
        session: session,
        providerId: 'copilot',
        providerLabel: "Copilot's CLI",
        launchArgv: const [r'C:\Program Files\Copilot\copilot.exe', '--acp'],
        cwd: r'C:\Users\demo\project folder',
      );
      expect(started.bridgeId, _bridgeId);
      expect((await service.list(session)).single.id, _bridgeId);
      expect((await service.status(session, _bridgeId)).id, _bridgeId);
      await service.stop(session, _bridgeId);

      expect(commands, hasLength(4));
      final script = _decodePowerShellScript(commands.first);
      expect(
        script,
        contains(r"$__flAcpHelper='C:\Users\demo\.monkeyssh\monkeymux.exe'"),
      );
      expect(script, contains("'Copilot''s CLI'"));
      expect(script, contains(r"'C:\Users\demo\project folder'"));
      expect(
        _decodePowerShellScript(commands.last),
        contains("\$__flAcpArgs=@('acp','stop','$_bridgeId')"),
      );
    },
  );

  test('unwraps split output frames and sends ACKs', () async {
    late _TestChannel channel;
    channel = _TestChannel(
      onWrite: (value) {
        final message = jsonDecode(value) as Map<String, dynamic>;
        if (message['type'] == 'hello') {
          channel.addSplitText(
            _frame({
              'version': 1,
              'type': 'hello',
              'bridgeId': _bridgeId,
              'clientId': _otherBridgeId,
              'canSend': true,
              'bridge': _metadata(nextSequence: 1),
            }),
            [2, 11, 37],
          );
          final output = _frame({
            'version': 1,
            'type': 'output',
            'bridgeId': _bridgeId,
            'sequence': 1,
            'data': {
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': {'text': 'café 🚀'},
            },
          });
          final bytes = utf8.encode(output);
          channel.stdout.add(
            Uint8List.fromList(bytes.sublist(0, bytes.length - 3)),
          );
          channel.stdout.add(
            Uint8List.fromList(bytes.sublist(bytes.length - 3)),
          );
        }
      },
    );
    final client = _MockSshClient();
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) async => channel.session);
    final service = MonkeyMuxAcpBridgeService(
      installer: _FakeInstaller(
        const MonkeyMuxInstallation(
          executablePath: '/helper',
          platform: 'linux-amd64',
          version: 'test',
        ),
      ),
    );
    final transport = service.connect(
      sessionProvider: () async => _sshSession(client),
      bridgeId: _bridgeId,
      providerId: 'copilot',
    );
    addTearDown(transport.close);

    final incoming = await transport.incoming.first;

    expect(
      jsonDecode(utf8.decode(incoming).trim()),
      containsPair('method', 'session/update'),
    );
    await _waitUntil(
      () => channel.writes
          .map(_decodeFrame)
          .any((message) => message['type'] == 'ack'),
    );
    expect(channel.writes.map(_decodeFrame), contains(containsPair('ack', 1)));
  });

  test('replacement transport resumes from the supplied bridge ACK', () async {
    late _TestChannel channel;
    channel = _TestChannel(
      onWrite: (value) {
        final message = jsonDecode(value) as Map<String, dynamic>;
        if (message['type'] != 'hello') return;
        expect(message['lastAck'], 23);
        expect(message, isNot(contains('replayMode')));
        channel.addText(
          _frame({
            'version': 1,
            'type': 'hello',
            'bridgeId': _bridgeId,
            'clientId': _otherBridgeId,
            'canSend': true,
            'bridge': _metadata(nextSequence: 23),
          }),
        );
      },
    );
    final client = _MockSshClient();
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) async => channel.session);
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
          lastAcknowledgedSequence: 23,
        );
    addTearDown(transport.close);

    await _waitUntil(() => transport.isConnected);
    expect(transport.lastDeliveredSequence, 23);
    expect(transport.didSkipHistoricalReplay(), isFalse);
  });

  test('safe short direct replay holds client input until high-water', () async {
    late _TestChannel channel;
    channel = _TestChannel(
      onWrite: (value) {
        final message = jsonDecode(value) as Map<String, dynamic>;
        if (message['type'] != 'hello') return;
        expect(message['lastAck'], 0);
        expect(message['replayMode'], 'adaptive');
        channel
          ..addText(
            _frame({
              'version': 1,
              'type': 'hello',
              'bridgeId': _bridgeId,
              'clientId': _otherBridgeId,
              'canSend': true,
              'replayMode': 'direct',
              'bridge': _metadata(nextSequence: 2, pendingRequestCount: 0),
            }),
          )
          ..addText(
            _frame({
              'version': 1,
              'type': 'output',
              'bridgeId': _bridgeId,
              'sequence': 1,
              'data': {'jsonrpc': '2.0', 'method': 'short-history/1'},
            }),
          );
      },
    );
    final client = _MockSshClient();
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) async => channel.session);
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
        );
    addTearDown(transport.close);
    final incoming = StreamIterator<List<int>>(transport.incoming);
    addTearDown(incoming.cancel);

    expect(await incoming.moveNext(), isTrue);
    expect(
      (jsonDecode(utf8.decode(incoming.current)) as Map)['method'],
      'short-history/1',
    );
    for (var id = 1; id <= 32; id++) {
      await transport.write(
        utf8.encode(
          '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': 'initialize'})}\n',
        ),
      );
    }
    await expectLater(
      transport.write(
        utf8.encode(
          '${jsonEncode({'jsonrpc': '2.0', 'id': 33, 'method': 'initialize'})}\n',
        ),
      ),
      throwsA(
        isA<MonkeyMuxAcpBridgeException>().having(
          (error) => error.kind,
          'kind',
          MonkeyMuxAcpBridgeErrorKind.frameTooLarge,
        ),
      ),
    );
    expect(
      channel.writes.map(_decodeFrame),
      isNot(contains(containsPair('type', 'input'))),
    );

    channel.addText(
      _frame({
        'version': 1,
        'type': 'output',
        'bridgeId': _bridgeId,
        'sequence': 2,
        'data': {'jsonrpc': '2.0', 'method': 'short-history/2'},
      }),
    );
    expect(await incoming.moveNext(), isTrue);
    await _waitUntil(
      () =>
          channel.writes
              .map(_decodeFrame)
              .where((message) => message['type'] == 'input')
              .length ==
          32,
    );

    expect(transport.lastDeliveredSequence, 2);
    expect(transport.didSkipHistoricalReplay(), isFalse);
  });

  test('direct replay resumes before flushing input after channel loss', () async {
    final channels = <_TestChannel>[];
    var opens = 0;
    final releaseSecondReplay = Completer<void>();
    final client = _MockSshClient();
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      _,
    ) async {
      opens += 1;
      late _TestChannel channel;
      channel = _TestChannel(
        onWrite: (value) {
          final message = jsonDecode(value) as Map<String, dynamic>;
          if (message['type'] != 'hello') return;
          if (opens == 1) {
            expect(message['lastAck'], 0);
            expect(message['replayMode'], 'adaptive');
            channel.addText(
              '${_frame({'version': 1, 'type': 'hello', 'bridgeId': _bridgeId, 'clientId': _otherBridgeId, 'canSend': true, 'replayMode': 'direct', 'bridge': _metadata(nextSequence: 2)})}${_frame({
                'version': 1,
                'type': 'output',
                'bridgeId': _bridgeId,
                'sequence': 1,
                'data': {'jsonrpc': '2.0', 'method': 'direct/1'},
              })}',
            );
            unawaited(channel.remoteClose());
            return;
          }
          expect(message['lastAck'], 1);
          expect(message, isNot(contains('replayMode')));
          channel.addText(
            _frame({
              'version': 1,
              'type': 'hello',
              'bridgeId': _bridgeId,
              'clientId': _otherBridgeId,
              'canSend': true,
              'bridge': _metadata(nextSequence: 2),
            }),
          );
          unawaited(
            releaseSecondReplay.future.then(
              (_) => channel.addText(
                _frame({
                  'version': 1,
                  'type': 'output',
                  'bridgeId': _bridgeId,
                  'sequence': 2,
                  'data': {'jsonrpc': '2.0', 'method': 'direct/2'},
                }),
              ),
            ),
          );
        },
      );
      channels.add(channel);
      return channel.session;
    });
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
          reconnectBackoff: const [Duration(milliseconds: 100)],
        );
    addTearDown(transport.close);
    final incoming = StreamIterator<List<int>>(transport.incoming);
    addTearDown(incoming.cancel);

    expect(await incoming.moveNext(), isTrue);
    await _waitUntil(() => !transport.isConnected);
    await expectLater(
      transport.write(
        utf8.encode(
          '${jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'})}\n',
        ),
      ),
      throwsA(
        isA<MonkeyMuxAcpBridgeException>().having(
          (error) => error.kind,
          'kind',
          MonkeyMuxAcpBridgeErrorKind.sshChannel,
        ),
      ),
    );
    await _waitUntil(() => channels.length == 2);

    releaseSecondReplay.complete();
    expect(await incoming.moveNext(), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(
      channels[1].writes.map(_decodeFrame),
      isNot(contains(containsPair('type', 'input'))),
    );
    expect(transport.lastDeliveredSequence, 2);
  });

  test('legacy bridge with no pending requests skips queued replay', () async {
    final channels = <_TestChannel>[];
    var opens = 0;
    final client = _MockSshClient();
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      _,
    ) async {
      opens += 1;
      late _TestChannel channel;
      channel = _TestChannel(
        onWrite: (value) {
          final message = jsonDecode(value) as Map<String, dynamic>;
          if (message['type'] != 'hello') return;
          if (opens == 1) {
            expect(message['lastAck'], 0);
            expect(message['replayMode'], 'adaptive');
            channel.addText(
              '${_frame({'version': 1, 'type': 'hello', 'bridgeId': _bridgeId, 'clientId': _otherBridgeId, 'canSend': true, 'bridge': _metadata(nextSequence: 40000, pendingRequestCount: 0)})}${_frame({
                'version': 1,
                'type': 'output',
                'bridgeId': _bridgeId,
                'sequence': 1,
                'data': {'jsonrpc': '2.0', 'method': 'stale-history'},
              })}',
            );
            return;
          }
          expect(message['lastAck'], 40000);
          expect(message, isNot(contains('replayMode')));
          channel
            ..addText(
              _frame({
                'version': 1,
                'type': 'hello',
                'bridgeId': _bridgeId,
                'clientId': _otherBridgeId,
                'canSend': true,
                'bridge': _metadata(
                  nextSequence: 40000,
                  pendingRequestCount: 0,
                ),
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'output',
                'bridgeId': _bridgeId,
                'sequence': 40001,
                'data': {'jsonrpc': '2.0', 'method': 'live'},
              }),
            );
        },
      );
      channels.add(channel);
      return channel.session;
    });
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
          reconnectBackoff: const [Duration(milliseconds: 1)],
        );
    addTearDown(transport.close);

    final incoming =
        jsonDecode(utf8.decode(await transport.incoming.first))
            as Map<String, dynamic>;

    expect(channels, hasLength(2));
    expect(incoming['method'], 'live');
    expect(transport.lastDeliveredSequence, 40001);
    expect(transport.didSkipHistoricalReplay(), isTrue);
  });

  test(
    'fresh attach baselines history but preserves pending requests',
    () async {
      late _TestChannel channel;
      channel = _TestChannel(
        onWrite: (value) {
          final message = jsonDecode(value) as Map<String, dynamic>;
          if (message['type'] != 'hello') return;
          expect(message['lastAck'], 0);
          expect(message['replayMode'], 'adaptive');
          channel
            ..addText(
              _frame({
                'version': 1,
                'type': 'hello',
                'bridgeId': _bridgeId,
                'clientId': _otherBridgeId,
                'canSend': true,
                'replayMode': 'pending',
                'bridge': _metadata(nextSequence: 40000),
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'pending',
                'bridgeId': _bridgeId,
                'data': {
                  'jsonrpc': '2.0',
                  'id': 'permission-1',
                  'method': 'session/request_permission',
                },
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'replay_end',
                'bridgeId': _bridgeId,
                'replayMode': 'pending',
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'output',
                'bridgeId': _bridgeId,
                'sequence': 40001,
                'data': {'jsonrpc': '2.0', 'method': 'live'},
              }),
            );
        },
      );
      final client = _MockSshClient();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => channel.session);
      final transport =
          MonkeyMuxAcpBridgeService(
            installer: _FakeInstaller(
              const MonkeyMuxInstallation(
                executablePath: '/helper',
                platform: 'linux-amd64',
                version: 'test',
              ),
            ),
          ).connect(
            sessionProvider: () async => _sshSession(client),
            bridgeId: _bridgeId,
            providerId: 'copilot',
          );
      addTearDown(transport.close);

      final incoming = await transport.incoming
          .take(2)
          .map(
            (bytes) => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
          )
          .toList();

      expect(incoming.map((message) => message['method']), [
        'session/request_permission',
        'live',
      ]);
      expect(transport.lastDeliveredSequence, 40001);
      await _waitUntil(
        () => channel.writes
            .map(_decodeFrame)
            .any((message) => message['ack'] == 40001),
      );
      final acknowledgements = channel.writes
          .map(_decodeFrame)
          .where((message) => message['type'] == 'ack')
          .map((message) => message['ack']);
      expect(acknowledgements, containsAllInOrder([40000, 40001]));
    },
  );

  test(
    'retries pending replay when the channel drops before replay end',
    () async {
      final channels = <_TestChannel>[];
      var opens = 0;
      final client = _MockSshClient();
      when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
        _,
      ) async {
        opens += 1;
        late _TestChannel channel;
        channel = _TestChannel(
          onWrite: (value) {
            final message = jsonDecode(value) as Map<String, dynamic>;
            if (message['type'] != 'hello') return;
            expect(message['lastAck'], 0);
            expect(message['replayMode'], 'adaptive');
            channel
              ..addText(
                _frame({
                  'version': 1,
                  'type': 'hello',
                  'bridgeId': _bridgeId,
                  'clientId': _otherBridgeId,
                  'canSend': true,
                  'replayMode': 'pending',
                  'bridge': _metadata(nextSequence: 5),
                }),
              )
              ..addText(
                _frame({
                  'version': 1,
                  'type': 'pending',
                  'bridgeId': _bridgeId,
                  'data': {
                    'jsonrpc': '2.0',
                    'id': 'permission-retried',
                    'method': 'session/request_permission',
                  },
                }),
              );
            if (opens == 1) {
              unawaited(channel.remoteClose());
              return;
            }
            channel
              ..addText(
                _frame({
                  'version': 1,
                  'type': 'replay_end',
                  'bridgeId': _bridgeId,
                  'replayMode': 'pending',
                }),
              )
              ..addText(
                _frame({
                  'version': 1,
                  'type': 'output',
                  'bridgeId': _bridgeId,
                  'sequence': 6,
                  'data': {'jsonrpc': '2.0', 'method': 'live-after-retry'},
                }),
              );
          },
        );
        channels.add(channel);
        return channel.session;
      });
      final transport =
          MonkeyMuxAcpBridgeService(
            installer: _FakeInstaller(
              const MonkeyMuxInstallation(
                executablePath: '/helper',
                platform: 'linux-amd64',
                version: 'test',
              ),
            ),
          ).connect(
            sessionProvider: () async => _sshSession(client),
            bridgeId: _bridgeId,
            providerId: 'copilot',
            reconnectBackoff: const [Duration(milliseconds: 1)],
          );
      addTearDown(transport.close);

      final incoming = await transport.incoming
          .take(2)
          .map(
            (bytes) => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
          )
          .toList();

      expect(channels, hasLength(2));
      expect(incoming.map((message) => message['method']), [
        'session/request_permission',
        'live-after-retry',
      ]);
      expect(transport.lastDeliveredSequence, 6);
      await _waitUntil(
        () => channels[1].writes
            .map(_decodeFrame)
            .any((message) => message['ack'] == 6),
      );
      expect(
        channels[1].writes.map(_decodeFrame),
        containsAll([containsPair('ack', 5), containsPair('ack', 6)]),
      );
    },
  );

  test('reconnects and resumes replay from the last ACK', () async {
    final channels = <_TestChannel>[];
    var opens = 0;
    final client = _MockSshClient();
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      _,
    ) async {
      opens += 1;
      late _TestChannel channel;
      channel = _TestChannel(
        onWrite: (value) {
          final message = jsonDecode(value) as Map<String, dynamic>;
          if (message['type'] != 'hello') return;
          channel
            ..addText(
              _frame({
                'version': 1,
                'type': 'hello',
                'bridgeId': _bridgeId,
                'clientId': _otherBridgeId,
                'canSend': true,
                'bridge': _metadata(nextSequence: opens),
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'output',
                'bridgeId': _bridgeId,
                'sequence': opens,
                'data': {'jsonrpc': '2.0', 'method': 'event/$opens'},
              }),
            );
        },
      );
      channels.add(channel);
      return channel.session;
    });
    final session = _sshSession(client);
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => session,
          bridgeId: _bridgeId,
          providerId: 'copilot',
          reconnectBackoff: const [Duration(milliseconds: 1)],
        );
    addTearDown(transport.close);
    final incoming = <Map<String, dynamic>>[];
    final subscription = transport.incoming.listen((bytes) {
      incoming.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    });
    addTearDown(subscription.cancel);

    await _waitUntil(() => incoming.length == 1);
    await channels.first.remoteClose();
    await _waitUntil(() => incoming.length == 2);

    final secondHello = channels[1].writes.map(_decodeFrame).first;
    expect(secondHello['lastAck'], 1);
    expect(incoming.map((message) => message['method']), [
      'event/1',
      'event/2',
    ]);
  });

  test('reports overflow and accepts the first post-snapshot event', () async {
    late _TestChannel channel;
    channel = _TestChannel(
      onWrite: (value) {
        final message = jsonDecode(value) as Map<String, dynamic>;
        if (message['type'] != 'hello') return;
        channel
          ..addText(
            _frame({
              'version': 1,
              'type': 'hello',
              'bridgeId': _bridgeId,
              'clientId': _otherBridgeId,
              'canSend': true,
              'bridge': _metadata(nextSequence: 5),
            }),
          )
          ..addText(
            _frame({
              'version': 1,
              'type': 'overflow',
              'bridgeId': _bridgeId,
              'retainedFrom': 3,
            }),
          )
          ..addText(
            _frame({
              'version': 1,
              'type': 'output',
              'bridgeId': _bridgeId,
              'sequence': 3,
              'data': {'jsonrpc': '2.0', 'method': 'retained'},
            }),
          )
          ..addText(
            _frame({
              'version': 1,
              'type': 'output',
              'bridgeId': _bridgeId,
              'sequence': 6,
              'data': {'jsonrpc': '2.0', 'method': 'live'},
            }),
          );
      },
    );
    final client = _MockSshClient();
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) async => channel.session);
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
        );
    addTearDown(transport.close);
    final errorFuture = transport.errors.first;

    final bytes = await transport.incoming.take(2).toList();

    expect(
      (await errorFuture).kind,
      MonkeyMuxAcpBridgeErrorKind.replayOverflow,
    );
    expect(
      bytes.map(
        (frame) =>
            (jsonDecode(utf8.decode(frame)) as Map<String, dynamic>)['method'],
      ),
      ['retained', 'live'],
    );
    expect(transport.lastDeliveredSequence, 6);
  });

  test(
    'malformed live status metadata fails the transport terminally',
    () async {
      late _TestChannel channel;
      channel = _TestChannel(
        onWrite: (value) {
          final message = jsonDecode(value) as Map<String, dynamic>;
          if (message['type'] != 'hello') return;
          channel
            ..addText(
              _frame({
                'version': 1,
                'type': 'hello',
                'bridgeId': _bridgeId,
                'clientId': _otherBridgeId,
                'canSend': true,
                'bridge': _metadata(),
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'status',
                'bridgeId': _bridgeId,
                'bridge': 'invalid',
              }),
            );
        },
      );
      final client = _MockSshClient();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => channel.session);
      final transport =
          MonkeyMuxAcpBridgeService(
            installer: _FakeInstaller(
              const MonkeyMuxInstallation(
                executablePath: '/helper',
                platform: 'linux-amd64',
                version: 'test',
              ),
            ),
          ).connect(
            sessionProvider: () async => _sshSession(client),
            bridgeId: _bridgeId,
            providerId: 'copilot',
          );
      addTearDown(transport.close);

      expect(
        (await transport.errors.first).kind,
        MonkeyMuxAcpBridgeErrorKind.invalidMetadata,
      );
      await expectLater(transport.incoming, emitsDone);
    },
  );

  test('large replay yields while preserving every ordered frame', () async {
    const outputCount = 600;
    late _TestChannel channel;
    channel = _TestChannel(
      onWrite: (value) {
        final message = jsonDecode(value) as Map<String, dynamic>;
        if (message['type'] != 'hello') return;
        final replay = StringBuffer()
          ..write(
            _frame({
              'version': 1,
              'type': 'hello',
              'bridgeId': _bridgeId,
              'clientId': _otherBridgeId,
              'canSend': true,
              'bridge': _metadata(nextSequence: outputCount),
            }),
          )
          ..write(
            _frame({
              'version': 1,
              'type': 'overflow',
              'bridgeId': _bridgeId,
              'retainedFrom': 1,
            }),
          );
        for (var sequence = 1; sequence <= outputCount; sequence++) {
          replay.write(
            _frame({
              'version': 1,
              'type': 'output',
              'bridgeId': _bridgeId,
              'sequence': sequence,
              'data': {'jsonrpc': '2.0', 'method': 'event/$sequence'},
            }),
          );
        }
        channel.addText(replay.toString());
      },
    );
    final client = _MockSshClient();
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) async => channel.session);
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
        );
    addTearDown(transport.close);

    final methods = <String>[];
    var eventLoopYielded = false;
    final replayComplete = Completer<void>();
    final subscription = transport.incoming.listen((bytes) {
      final message = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      methods.add(message['method']! as String);
      if (methods.length == 1) {
        Timer.run(() => eventLoopYielded = true);
      }
      if (methods.length == outputCount) replayComplete.complete();
    });
    addTearDown(subscription.cancel);

    await replayComplete.future;

    expect(eventLoopYielded, isTrue);
    expect(methods, hasLength(outputCount));
    expect(methods.first, 'event/1');
    expect(methods.last, 'event/$outputCount');
    expect(transport.lastDeliveredSequence, outputCount);
  });

  test(
    'accepts interior replay gaps through the hello high-water mark',
    () async {
      late _TestChannel channel;
      channel = _TestChannel(
        onWrite: (value) {
          final message = jsonDecode(value) as Map<String, dynamic>;
          if (message['type'] != 'hello') return;
          channel
            ..addText(
              _frame({
                'version': 1,
                'type': 'hello',
                'bridgeId': _bridgeId,
                'clientId': _otherBridgeId,
                'canSend': true,
                'bridge': _metadata(nextSequence: 5),
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'overflow',
                'bridgeId': _bridgeId,
                'retainedFrom': 1,
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'output',
                'bridgeId': _bridgeId,
                'sequence': 1,
                'data': {
                  'jsonrpc': '2.0',
                  'id': 'permission-1',
                  'method': 'session/request_permission',
                },
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'state',
                'bridgeId': _bridgeId,
                'sequence': 4,
                'state': 'running',
              }),
            )
            ..addText(
              _frame({
                'version': 1,
                'type': 'output',
                'bridgeId': _bridgeId,
                'sequence': 5,
                'data': {'jsonrpc': '2.0', 'method': 'tail'},
              }),
            );
        },
      );
      final client = _MockSshClient();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => channel.session);
      final transport =
          MonkeyMuxAcpBridgeService(
            installer: _FakeInstaller(
              const MonkeyMuxInstallation(
                executablePath: '/helper',
                platform: 'linux-amd64',
                version: 'test',
              ),
            ),
          ).connect(
            sessionProvider: () async => _sshSession(client),
            bridgeId: _bridgeId,
            providerId: 'copilot',
          );
      addTearDown(transport.close);
      final errors = <MonkeyMuxAcpBridgeException>[];
      final errorSubscription = transport.errors.listen(errors.add);
      addTearDown(errorSubscription.cancel);

      final incoming = await transport.incoming
          .take(2)
          .map(
            (bytes) => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
          )
          .toList();
      await Future<void>.delayed(Duration.zero);

      expect(incoming.first['method'], 'session/request_permission');
      expect(incoming.last['method'], 'tail');
      expect(errors.map((error) => error.kind), [
        MonkeyMuxAcpBridgeErrorKind.replayOverflow,
      ]);
      expect(transport.lastDeliveredSequence, 5);
      expect(transport.isConnected, isTrue);
    },
  );

  test('rejects a live gap after the replay high-water mark', () async {
    late _TestChannel channel;
    channel = _TestChannel(
      onWrite: (value) {
        final message = jsonDecode(value) as Map<String, dynamic>;
        if (message['type'] != 'hello') return;
        channel
          ..addText(
            _frame({
              'version': 1,
              'type': 'hello',
              'bridgeId': _bridgeId,
              'clientId': _otherBridgeId,
              'canSend': true,
              'bridge': _metadata(nextSequence: 3),
            }),
          )
          ..addText(
            _frame({
              'version': 1,
              'type': 'overflow',
              'bridgeId': _bridgeId,
              'retainedFrom': 1,
            }),
          )
          ..addText(
            _frame({
              'version': 1,
              'type': 'output',
              'bridgeId': _bridgeId,
              'sequence': 1,
              'data': {
                'jsonrpc': '2.0',
                'id': 'permission-1',
                'method': 'session/request_permission',
              },
            }),
          )
          ..addText(
            _frame({
              'version': 1,
              'type': 'state',
              'bridgeId': _bridgeId,
              'sequence': 3,
              'state': 'running',
            }),
          )
          ..addText(
            _frame({
              'version': 1,
              'type': 'output',
              'bridgeId': _bridgeId,
              'sequence': 5,
              'data': {'jsonrpc': '2.0', 'method': 'live-gap'},
            }),
          );
      },
    );
    final client = _MockSshClient();
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) async => channel.session);
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
        );
    addTearDown(transport.close);

    final errors = await transport.errors.take(2).toList();

    expect(errors.map((error) => error.kind), [
      MonkeyMuxAcpBridgeErrorKind.replayOverflow,
      MonkeyMuxAcpBridgeErrorKind.sequenceGap,
    ]);
    expect(transport.lastDeliveredSequence, 3);
    expect(transport.isConnected, isFalse);
  });

  test('rejects non-writer connections and provider exit', () async {
    Future<MonkeyMuxAcpBridgeException> run({
      required bool canSend,
      required bool exit,
    }) async {
      late _TestChannel channel;
      channel = _TestChannel(
        onWrite: (value) {
          final message = jsonDecode(value) as Map<String, dynamic>;
          if (message['type'] != 'hello') return;
          channel.addText(
            _frame({
              'version': 1,
              'type': 'hello',
              'bridgeId': _bridgeId,
              'clientId': _otherBridgeId,
              'canSend': canSend,
              'bridge': _metadata(),
            }),
          );
          if (canSend && exit) {
            channel.addText(
              _frame({
                'version': 1,
                'type': 'state',
                'bridgeId': _bridgeId,
                'sequence': 1,
                'state': 'exited',
                'exitCode': 17,
              }),
            );
          }
        },
      );
      final client = _MockSshClient();
      when(
        () => client.execute(any(), pty: any(named: 'pty')),
      ).thenAnswer((_) async => channel.session);
      final transport =
          MonkeyMuxAcpBridgeService(
            installer: _FakeInstaller(
              const MonkeyMuxInstallation(
                executablePath: '/helper',
                platform: 'linux-amd64',
                version: 'test',
              ),
            ),
          ).connect(
            sessionProvider: () async => _sshSession(client),
            bridgeId: _bridgeId,
            providerId: 'copilot',
          );
      final error = await transport.errors.first;
      await transport.close();
      return error;
    }

    expect(
      (await run(canSend: false, exit: false)).kind,
      MonkeyMuxAcpBridgeErrorKind.nonWriter,
    );
    expect(
      (await run(canSend: true, exit: true)).kind,
      MonkeyMuxAcpBridgeErrorKind.providerExited,
    );
  });

  test('buffers split ACP input and wraps it as bridge input', () async {
    late _TestChannel channel;
    channel = _TestChannel(
      onWrite: (value) {
        final message = jsonDecode(value) as Map<String, dynamic>;
        if (message['type'] == 'hello') {
          channel.addText(
            _frame({
              'version': 1,
              'type': 'hello',
              'bridgeId': _bridgeId,
              'clientId': _otherBridgeId,
              'canSend': true,
              'bridge': _metadata(),
            }),
          );
        }
      },
    );
    final client = _MockSshClient();
    when(
      () => client.execute(any(), pty: any(named: 'pty')),
    ).thenAnswer((_) async => channel.session);
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
        );
    addTearDown(transport.close);
    await _waitUntil(() => transport.isConnected);
    final input = utf8.encode(
      '{"jsonrpc":"2.0","id":"café","method":"prompt"}\n',
    );

    await transport.write(input.sublist(0, input.length - 4));
    await transport.write(input.sublist(input.length - 4));
    await _waitUntil(
      () => channel.writes
          .map(_decodeFrame)
          .any((message) => message['type'] == 'input'),
    );

    final wrapped = channel.writes
        .map(_decodeFrame)
        .firstWhere((message) => message['type'] == 'input');
    expect(wrapped['data'], containsPair('method', 'prompt'));
  });

  test('explicit close only detaches locally and cancels reconnect', () async {
    final client = _MockSshClient();
    final commands = <String>[];
    final channel = _TestChannel();
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      invocation,
    ) async {
      commands.add(invocation.positionalArguments.single as String);
      return channel.session;
    });
    final transport =
        MonkeyMuxAcpBridgeService(
          installer: _FakeInstaller(
            const MonkeyMuxInstallation(
              executablePath: '/helper',
              platform: 'linux-amd64',
              version: 'test',
            ),
          ),
        ).connect(
          sessionProvider: () async => _sshSession(client),
          bridgeId: _bridgeId,
          providerId: 'copilot',
          reconnectBackoff: const [Duration(milliseconds: 20)],
          handshakeTimeout: const Duration(milliseconds: 20),
        );
    await _waitUntil(() => commands.isNotEmpty);

    await transport.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(commands, hasLength(1));
    expect(commands.single, isNot(contains("'stop'")));
    expect(channel.localCloseCount, 1);
  });

  test('surfaces failed helper process and cleans up the channel', () async {
    final client = _MockSshClient();
    final channel = _TestChannel();
    when(() => client.execute(any(), pty: any(named: 'pty'))).thenAnswer((
      _,
    ) async {
      scheduleMicrotask(channel.remoteClose);
      return channel.session;
    });
    final service = MonkeyMuxAcpBridgeService(
      installer: _FakeInstaller(
        const MonkeyMuxInstallation(
          executablePath: '/helper',
          platform: 'linux-amd64',
          version: 'test',
        ),
      ),
    );

    await expectLater(
      service.list(_sshSession(client)),
      throwsA(
        isA<MonkeyMuxAcpBridgeException>().having(
          (error) => error.kind,
          'kind',
          MonkeyMuxAcpBridgeErrorKind.helperProcess,
        ),
      ),
    );
    expect(channel.localCloseCount, 1);
  });
}
