import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_client_capability_service.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';
import 'package:monkeyssh/domain/services/diagnostics_log_service.dart';

void main() {
  group('AcpClientCapabilityService', () {
    late _ServerTransport transport;
    late AcpClient client;
    late _FakeFileSystem files;
    late _FakeTerminalExecutor terminals;
    late AcpPendingRequestRegistry registry;
    late AcpClientCapabilityService service;

    setUp(() {
      transport = _ServerTransport();
      client = AcpClient(AcpJsonRpcConnection(transport: transport));
      files = _FakeFileSystem();
      terminals = _FakeTerminalExecutor();
      registry = AcpPendingRequestRegistry();
      service = AcpClientCapabilityService(
        fileSystem: files,
        terminalExecutor: terminals,
        allowedRoots: const ['/workspace', '/C:/workspace'],
        registry: registry,
        limits: const AcpClientCapabilityLimits(
          maxFileBytes: 16,
          maxWriteBytes: 16,
          maxTerminalOutputBytes: 8,
          maxTerminals: 2,
        ),
      )..attach(client);
    });

    tearDown(() async {
      await service.close();
      await client.close();
    });

    test('advertises only configured capabilities', () {
      expect(service.capabilities.fileSystem?.readTextFile, isTrue);
      expect(service.capabilities.fileSystem?.writeTextFile, isTrue);
      expect(service.capabilities.terminal, isTrue);
      expect(
        AcpClientCapabilityService(
          fileSystem: null,
          terminalExecutor: null,
          allowedRoots: const [],
          registry: AcpPendingRequestRegistry(),
        ).capabilities.toJson(),
        {
          'terminal': false,
          'session': {
            'configOptions': {'boolean': {}},
          },
        },
      );
    });

    test('retains permissions and answers with exact option IDs', () async {
      transport.sendRequest('permission-1', 'session/request_permission', {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': 'call-1'},
        'options': [
          {'optionId': 'agent-option', 'name': 'Allow', 'kind': 'allow_once'},
        ],
      });
      await _settle();

      expect(registry.requests, hasLength(1));
      await service.selectPermission('permission-1', 'agent-option');

      expect(transport.responseFor('permission-1')['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'agent-option'},
      });
      expect(registry.requests, isEmpty);
    });

    test(
      'preserves a pending permission over detach and reconnect replay',
      () async {
        transport.sendRequest('permission-1', 'session/request_permission', {
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'call-1'},
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        });
        await _settle();
        await service.detach();
        expect(registry.requests, hasLength(1));

        final reconnectTransport = _ServerTransport();
        final reconnectClient = AcpClient(
          AcpJsonRpcConnection(transport: reconnectTransport),
        );
        service.attach(reconnectClient);
        reconnectTransport.sendRequest(
          'permission-1',
          'session/request_permission',
          {
            'sessionId': 'session-1',
            'toolCall': {'toolCallId': 'call-1'},
            'options': [
              {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
            ],
          },
        );
        await _settle();

        await service.selectPermission('permission-1', 'allow');
        expect(
          reconnectTransport.responseFor('permission-1')['result'],
          isNotNull,
        );
        await reconnectClient.close();
      },
    );

    test('returns method not found for unknown server methods', () async {
      transport.sendRequest('unknown-1', 'terminal/not_a_method', {});
      await _settle();

      expect(transport.responseFor('unknown-1')['error'], {
        'code': -32601,
        'message': 'Method not found',
      });
    });

    test('reads UTF-8 text and obeys line selections', () async {
      files.files['/workspace/a.txt'] = Uint8List.fromList(
        utf8.encode('one\ntwo\nthree\n'),
      );
      transport.sendRequest('read-1', 'fs/read_text_file', {
        'sessionId': 'session-1',
        'path': '/workspace/a.txt',
        'line': 2,
        'limit': 1,
      });
      await _settle();

      expect(transport.responseFor('read-1')['result'], {'content': 'two\n'});
    });

    test(
      'rejects relative, traversal, oversize, and non-text file reads',
      () async {
        files.files['/workspace/large.txt'] = Uint8List(17);
        files.files['/workspace/binary.txt'] = Uint8List.fromList([0xff]);
        for (final entry in <(String, String)>[
          ('relative', 'file.txt'),
          ('traversal', '/workspace/../secret.txt'),
          ('large', '/workspace/large.txt'),
          ('binary', '/workspace/binary.txt'),
        ]) {
          transport.sendRequest(entry.$1, 'fs/read_text_file', {
            'sessionId': 'session-1',
            'path': entry.$2,
          });
        }
        await _settle();

        for (final id in ['relative', 'traversal', 'large', 'binary']) {
          expect((transport.responseFor(id)['error']! as Map)['code'], -32000);
        }
      },
    );

    test(
      'queues writes until explicit approval and enforces byte limits',
      () async {
        transport.sendRequest('write-1', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/a.txt',
          'content': 'edited',
        });
        await _settle();
        expect(transport.responseForOrNull('write-1'), isNull);
        expect(files.files['/workspace/a.txt'], isNull);

        await service.approveWrite('write-1');
        expect(utf8.decode(files.files['/workspace/a.txt']!), 'edited');
        expect(transport.responseFor('write-1')['result'], isNull);

        transport.sendRequest('write-too-big', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/b.txt',
          'content': '01234567890123456',
        });
        await _settle();
        expect(
          (transport.responseFor('write-too-big')['error']! as Map)['code'],
          -32000,
        );
      },
    );

    test(
      'creates concurrent terminals, truncates output, waits, kills, and releases',
      () async {
        transport.sendRequest('create-1', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'echo',
          'args': ['hello'],
          'cwd': '/workspace',
          'outputByteLimit': 8,
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-1')['result']! as Map)['terminalId']
                as String;
        final process = terminals.processes.single
          ..addOutput(utf8.encode('1234'), utf8.encode('56789'));
        await _settle();

        transport.sendRequest('output-1', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        final output = transport.responseFor('output-1')['result']! as Map;
        expect(output['output'], '23456789');
        expect(output['truncated'], isTrue);

        process.exit(const AcpTerminalExitStatus(exitCode: 7));
        transport.sendRequest('wait-1', 'terminal/wait_for_exit', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(transport.responseFor('wait-1')['result'], {
          'exitCode': 7,
          'signal': null,
        });

        transport.sendRequest('release-1', 'terminal/release', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(transport.responseFor('release-1')['result'], isNull);
        transport.sendRequest('output-released', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(
          (transport.responseFor('output-released')['error']! as Map)['code'],
          -32000,
        );
      },
    );

    test(
      'kills a live terminal and explicit cleanup cancels unresolved requests',
      () async {
        transport.sendRequest('create-1', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'long-task',
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-1')['result']! as Map)['terminalId']
                as String;
        transport.sendRequest('kill-1', 'terminal/kill', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(terminals.processes.single.killed, isTrue);

        transport.sendRequest('permission-1', 'session/request_permission', {
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'call-1'},
          'options': [
            {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
          ],
        });
        await _settle();
        await service.close();
        expect(transport.responseFor('permission-1')['result'], {
          'outcome': {'outcome': 'cancelled'},
        });
      },
    );
  });

  test(
    'quotes Windows terminal commands without leaking raw values to diagnostics',
    () {
      final command = buildAcpRemoteTerminalCommand(
        command: r'C:\tool with spaces.exe',
        arguments: const ['a b'],
        environment: const {'TOKEN': 'secret'},
        cwd: '/C:/workspace',
        windows: true,
      );
      expect(command, startsWith('powershell -NoProfile'));
      expect(command, isNot(contains('secret')));
    },
  );

  test('diagnostics retain only safe ACP request metadata', () async {
    final transport = _ServerTransport();
    final client = AcpClient(AcpJsonRpcConnection(transport: transport));
    final logger = _RecordingLogger();
    final service = AcpClientCapabilityService(
      fileSystem: const _ThrowingFileSystem(),
      terminalExecutor: null,
      allowedRoots: const ['/workspace'],
      registry: AcpPendingRequestRegistry(),
      diagnostics: logger,
    )..attach(client);
    transport.sendRequest('read-1', 'fs/read_text_file', {
      'sessionId': 'session-1',
      'path': '/workspace/private.txt',
    });
    await _settle();

    expect(logger.warningFields.single, containsPair('methodCategory', 'fs'));
    expect(logger.warningFields.single.keys, isNot(contains('path')));
    expect(logger.warningFields.single.keys, isNot(contains('content')));
    expect(logger.warningFields.single.keys, isNot(contains('command')));
    await service.close();
    await client.close();
  });
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

final class _ServerTransport implements AcpTransport {
  final _incoming = StreamController<List<int>>();
  final messages = <Map<String, Object?>>[];

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  @override
  Future<void> close() => _incoming.close();

  void sendRequest(Object id, String method, Object? params) {
    _incoming.add(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n',
      ),
    );
  }

  @override
  Future<void> write(List<int> bytes) async {
    messages.add(
      (jsonDecode(utf8.decode(bytes).trim()) as Map).cast<String, Object?>(),
    );
  }

  Map<String, Object?> responseFor(String id) =>
      messages.lastWhere((message) => message['id'] == id);

  Map<String, Object?>? responseForOrNull(String id) {
    for (final message in messages.reversed) {
      if (message['id'] == id) return message;
    }
    return null;
  }
}

final class _FakeFileSystem implements AcpRemoteFileSystem {
  final files = <String, Uint8List>{};

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) async {
    final bytes =
        files[path] ??
        (throw const AcpClientCapabilityException('Missing file'));
    if (bytes.length > maxBytes) {
      throw const AcpLimitExceededException(
        'File exceeds the configured limit',
      );
    }

    return bytes;
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    files[path] = bytes;
  }
}

final class _FakeTerminalExecutor implements AcpTerminalExecutor {
  final processes = <_FakeTerminalProcess>[];
  final commands = <String>[];

  @override
  Future<AcpTerminalProcess> start(String command) async {
    commands.add(command);
    final process = _FakeTerminalProcess();
    processes.add(process);
    return process;
  }
}

final class _FakeTerminalProcess implements AcpTerminalProcess {
  final _stdout = StreamController<List<int>>.broadcast();
  final _stderr = StreamController<List<int>>.broadcast();
  final _exit = Completer<AcpTerminalExitStatus>();
  bool killed = false;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<void> get done => _exit.future.then((_) {});

  @override
  void kill() {
    killed = true;
    exit(const AcpTerminalExitStatus(signal: 'KILL'));
  }

  void exit(AcpTerminalExitStatus status) {
    if (_exit.isCompleted) return;
    _exit.complete(status);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
  }

  void addStdout(List<int> bytes) => _stdout.add(bytes);

  void addStderr(List<int> bytes) => _stderr.add(bytes);

  void addOutput(List<int> stdout, List<int> stderr) {
    addStdout(stdout);
    addStderr(stderr);
  }

  @override
  Future<AcpTerminalExitStatus> waitForExit() => _exit.future;
}

final class _ThrowingFileSystem implements AcpRemoteFileSystem {
  const _ThrowingFileSystem();

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) =>
      throw StateError('unexpected remote failure');

  @override
  Future<void> write(String path, Uint8List bytes) =>
      throw StateError('unexpected remote failure');
}

final class _RecordingLogger implements DiagnosticsLogger {
  final warningFields = <Map<String, Object?>>[];

  @override
  void debug(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void error(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void info(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {}

  @override
  void warning(
    String category,
    String message, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => warningFields.add(Map<String, Object?>.from(fields));
}
