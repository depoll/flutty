import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
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
          maxTerminalOutputBytes: 2048,
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
          '_meta': {'subagent-transcript': true, 'terminal-auth': true},
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
      'native YOLO auto-approves allow-once permissions and validated writes',
      () async {
        await service.close();
        registry = AcpPendingRequestRegistry();
        service = AcpClientCapabilityService(
          fileSystem: files,
          terminalExecutor: terminals,
          allowedRoots: const ['/workspace'],
          registry: registry,
          autoApprovePermissions: true,
          limits: const AcpClientCapabilityLimits(maxWriteBytes: 16),
        )..attach(client);

        transport
          ..sendRequest('permission-yolo', 'session/request_permission', {
            'sessionId': 'session-1',
            'toolCall': {'toolCallId': 'call-1'},
            'options': [
              {
                'optionId': 'persist',
                'name': 'Always allow',
                'kind': 'allow_always',
              },
              {'optionId': 'once', 'name': 'Allow once', 'kind': 'allow_once'},
            ],
          })
          ..sendRequest('write-yolo', 'fs/write_text_file', {
            'sessionId': 'session-1',
            'path': '/workspace/a.txt',
            'content': 'edited',
          });
        await _settle();

        expect(transport.responseFor('permission-yolo')['result'], {
          'outcome': {'outcome': 'selected', 'optionId': 'once'},
        });
        expect(transport.responseFor('write-yolo')['result'], isNull);
        expect(utf8.decode(files.files['/workspace/a.txt']!), 'edited');
        expect(registry.requests, isEmpty);
      },
    );

    test('runtime YOLO overrides stay scoped to one shared session', () async {
      service.setSessionAutoApprovePermissions('session-1', enabled: true);
      transport
        ..sendRequest('permission-yolo-1', 'session/request_permission', {
          'sessionId': 'session-1',
          'toolCall': {'toolCallId': 'call-1'},
          'options': [
            {'optionId': 'once-1', 'name': 'Allow once', 'kind': 'allow_once'},
          ],
        })
        ..sendRequest('permission-ask-2', 'session/request_permission', {
          'sessionId': 'session-2',
          'toolCall': {'toolCallId': 'call-2'},
          'options': [
            {'optionId': 'once-2', 'name': 'Allow once', 'kind': 'allow_once'},
          ],
        });
      await _settle();

      expect(transport.responseFor('permission-yolo-1')['result'], {
        'outcome': {'outcome': 'selected', 'optionId': 'once-1'},
      });
      expect(registry.requests.map((request) => request.sessionId), [
        'session-2',
      ]);

      service.setSessionAutoApprovePermissions('session-1', enabled: false);
      transport.sendRequest('permission-ask-1', 'session/request_permission', {
        'sessionId': 'session-1',
        'toolCall': {'toolCallId': 'call-3'},
        'options': [
          {'optionId': 'once-3', 'name': 'Allow once', 'kind': 'allow_once'},
        ],
      });
      await _settle();
      expect(registry.requests.map((request) => request.sessionId).toSet(), {
        'session-1',
        'session-2',
      });
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

    test(
      'closeSession cancels only the pending requests for that session, '
      'leaving another session sharing the same registry untouched',
      () async {
        transport
          ..sendRequest('permission-1', 'session/request_permission', {
            'sessionId': 'session-1',
            'toolCall': {'toolCallId': 'call-1'},
            'options': [
              {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
            ],
          })
          ..sendRequest('permission-2', 'session/request_permission', {
            'sessionId': 'session-2',
            'toolCall': {'toolCallId': 'call-2'},
            'options': [
              {'optionId': 'allow', 'name': 'Allow', 'kind': 'allow_once'},
            ],
          });
        await _settle();
        expect(registry.requests, hasLength(2));

        await service.closeSession('session-1');

        // session-1's request was cancelled and removed...
        expect(transport.responseFor('permission-1')['result'], {
          'outcome': {'outcome': 'cancelled'},
        });
        // ...but session-2's is untouched: no response yet, still pending.
        expect(transport.responseForOrNull('permission-2'), isNull);
        expect(registry.requests, hasLength(1));
        expect(registry.requests.single.sessionId, 'session-2');
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

    test('rejects a read that resolves through an escaping symlink', () async {
      files.canonicalPaths['/workspace/link/private.txt'] = '/private.txt';
      transport.sendRequest('read-link', 'fs/read_text_file', {
        'sessionId': 'session-1',
        'path': '/workspace/link/private.txt',
      });
      await _settle();

      expect(
        (transport.responseFor('read-link')['error']! as Map)['code'],
        -32000,
      );
      expect(files.readPaths, isEmpty);
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
      'rejects a write whose parent resolves through an escaping symlink',
      () async {
        files.canonicalWritePaths['/workspace/link/new.txt'] =
            '/private/new.txt';
        transport.sendRequest('write-link', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/link/new.txt',
          'content': 'edited',
        });
        await _settle();

        expect(
          (transport.responseFor('write-link')['error']! as Map)['code'],
          -32000,
        );
        expect(registry.requests, isEmpty);
      },
    );

    test(
      'write approval reports failures before removing the request',
      () async {
        transport.sendRequest('write-failure', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/a.txt',
          'content': 'edited',
        });
        await _settle();
        files.writeFailure = const FileSystemException('SFTP failed');

        await expectLater(
          () => service.approveWrite('write-failure'),
          throwsA(isA<FileSystemException>()),
        );
        expect(transport.responseFor('write-failure')['error'], {
          'code': -32000,
          'message': 'Remote operation failed',
        });
        expect(registry.requests, isEmpty);
      },
    );

    test(
      'write approval reports timeout before removing the request',
      () async {
        transport.sendRequest('write-timeout', 'fs/write_text_file', {
          'sessionId': 'session-1',
          'path': '/workspace/a.txt',
          'content': 'edited',
        });
        await _settle();
        files.writeFailure = TimeoutException('timed out');

        await expectLater(
          () => service.approveWrite('write-timeout'),
          throwsA(isA<TimeoutException>()),
        );
        expect(transport.responseFor('write-timeout')['error'], {
          'code': -32000,
          'message': 'Remote operation timed out',
        });
        expect(registry.requests, isEmpty);
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
      'retains a valid UTF-8 suffix across truncation and split chunks',
      () async {
        transport.sendRequest('create-utf8', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'echo',
          'outputByteLimit': 4,
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-utf8')['result']!
                    as Map)['terminalId']
                as String;
        terminals.processes.single
          ..addStdout(utf8.encode('x€'))
          ..addStdout(utf8.encode('yz'));
        await _settle();

        transport.sendRequest('output-utf8', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        expect(
          (transport.responseFor('output-utf8')['result']! as Map)['output'],
          'yz',
        );

        transport.sendRequest('create-split', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'echo',
          'outputByteLimit': 4,
        });
        await _settle();
        final splitTerminalId =
            (transport.responseFor('create-split')['result']!
                    as Map)['terminalId']
                as String;
        terminals.processes.last
          ..addStdout(<int>[0x61, 0x62, 0x63, 0xe2])
          ..addStdout(<int>[0x82])
          ..addStdout(<int>[0xac]);
        await _settle();

        transport.sendRequest('output-split', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': splitTerminalId,
        });
        await _settle();
        expect(
          (transport.responseFor('output-split')['result']! as Map)['output'],
          'c€',
        );
      },
    );

    test(
      'buffers many small chunks without retaining more than its cap',
      () async {
        const outputByteLimit = 1024;
        const chunkCount = 50000;
        transport.sendRequest('create-stress', 'terminal/create', {
          'sessionId': 'session-1',
          'command': 'echo',
          'outputByteLimit': outputByteLimit,
        });
        await _settle();
        final terminalId =
            (transport.responseFor('create-stress')['result']!
                    as Map)['terminalId']
                as String;
        final expected = StringBuffer();
        final process = terminals.processes.single;
        for (var index = 0; index < chunkCount; index += 1) {
          final codeUnit = 65 + index % 26;
          process.addStdout(<int>[codeUnit]);
          expected.writeCharCode(codeUnit);
        }
        await _settle();

        transport.sendRequest('output-stress', 'terminal/output', {
          'sessionId': 'session-1',
          'terminalId': terminalId,
        });
        await _settle();
        final result = transport.responseFor('output-stress')['result']! as Map;
        expect(result['truncated'], isTrue);
        expect(
          result['output'],
          expected.toString().substring(chunkCount - outputByteLimit),
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

  test('SFTP writes preserve executable and shared existing modes', () async {
    final executableSharedMode = SftpFileMode(
      groupWrite: false,
      otherWrite: false,
    );
    final sftp = _ModePreservingSftp(executableSharedMode);
    final fileSystem = AcpSftpRemoteFileSystem(() async => sftp);

    await fileSystem.write('/workspace/script', Uint8List.fromList([1]));

    expect(
      sftp.appliedModes.whereType<SftpFileMode>(),
      contains(executableSharedMode),
    );
    expect(sftp.appliedModes.last, executableSharedMode);
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
  final canonicalPaths = <String, String>{};
  final canonicalWritePaths = <String, String>{};
  final readPaths = <String>[];
  Exception? writeFailure;

  @override
  Future<String> canonicalizeExistingPath(String path) async =>
      canonicalPaths[path] ?? path;

  @override
  Future<String> canonicalizeWritePath(String path) async =>
      canonicalWritePaths[path] ?? canonicalPaths[path] ?? path;

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) async {
    readPaths.add(path);
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
    final failure = writeFailure;
    if (failure != null) throw failure;
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
  final _stdout = StreamController<List<int>>.broadcast(sync: true);
  final _stderr = StreamController<List<int>>.broadcast(sync: true);
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
  Future<String> canonicalizeExistingPath(String path) async => path;

  @override
  Future<String> canonicalizeWritePath(String path) async => path;

  @override
  Future<Uint8List> read(String path, {required int maxBytes}) =>
      throw StateError('unexpected remote failure');

  @override
  Future<void> write(String path, Uint8List bytes) =>
      throw StateError('unexpected remote failure');
}

final class _ModePreservingSftp implements SftpClient {
  _ModePreservingSftp(this._existingMode);

  final SftpFileMode _existingMode;
  final appliedModes = <SftpFileMode?>[];

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async =>
      SftpFileAttrs(mode: _existingMode);

  @override
  Future<SftpFile> open(
    String path, {
    SftpFileOpenMode mode = SftpFileOpenMode.read,
  }) async => _ModePreservingFile();

  @override
  Future<void> setStat(String path, SftpFileAttrs attrs) async {
    appliedModes.add(attrs.mode);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {}

  @override
  Future<void> remove(String filename) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ModePreservingFile implements SftpFile {
  var _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {}

  @override
  SftpFileWriter write(
    Stream<Uint8List> data, {
    int offset = 0,
    void Function(int bytesWritten)? onProgress,
  }) => SftpFileWriter(this, data, offset, onProgress);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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
