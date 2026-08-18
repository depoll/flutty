import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_content.dart';
import 'package:monkeyssh/domain/models/acp_protocol.dart';
import 'package:monkeyssh/domain/models/acp_updates.dart';
import 'package:monkeyssh/domain/services/acp_client.dart';
import 'package:monkeyssh/domain/services/acp_json_rpc_connection.dart';
import 'package:monkeyssh/domain/services/acp_transport.dart';

const _skipReason =
    'Requires localhost SSH. Run scripts/setup_acp_test_env.sh, source the '
    'printed env file, then rerun this test.';

final class _SshConfig {
  const _SshConfig({
    required this.host,
    required this.port,
    required this.user,
    required this.key,
    required this.bin,
    required this.cwd,
  });

  factory _SshConfig.fromEnvironment() => _SshConfig(
    host: Platform.environment['MONKEYSSH_ACP_E2E_HOST'] ?? 'localhost',
    port: Platform.environment['MONKEYSSH_ACP_E2E_PORT'] ?? '22',
    user: Platform.environment['MONKEYSSH_ACP_E2E_USER'] ?? '',
    key: Platform.environment['MONKEYSSH_ACP_E2E_KEY'] ?? '',
    bin: Platform.environment['MONKEYSSH_ACP_E2E_BIN'] ?? '',
    cwd: Platform.environment['MONKEYSSH_ACP_E2E_CWD'] ?? '',
  );

  final String host;
  final String port;
  final String user;
  final String key;
  final String bin;
  final String cwd;

  List<String> get sshArguments => [
    '-i',
    key,
    '-p',
    port,
    '-o',
    'BatchMode=yes',
    '-o',
    'StrictHostKeyChecking=no',
    '-o',
    'LogLevel=ERROR',
    '-o',
    'ConnectTimeout=5',
    '$user@$host',
  ];

  Future<ProcessResult> run(String command) =>
      Process.run('ssh', [...sshArguments, command]);
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

final class _SshBridgeTransport implements AcpTransport {
  _SshBridgeTransport(this.config, this.bridgeId);

  final _incoming = StreamController<List<int>>();
  final _hello = StreamController<void>.broadcast();
  final _errors = <Object>[];
  final _lineSubscriptions = <StreamSubscription<String>>[];
  final _stderrSubscriptions = <StreamSubscription<String>>[];
  final _seenSequences = <int>{};
  final _SshConfig config;
  final String bridgeId;
  Process? _process;
  int _lastAck = 0;
  bool holdAcknowledgements = false;
  int replayedSequenceCount = 0;

  List<Object> get errors => List<Object>.unmodifiable(_errors);

  @override
  Stream<List<int>> get incoming => _incoming.stream;

  Future<void> connect() async {
    final attachCommand =
        '${_shellQuote('${config.bin}/monkeymux')} acp attach '
        '${_shellQuote(bridgeId)}';
    final process = await Process.start('ssh', [
      ...config.sshArguments,
      attachCommand,
    ]);
    _process = process;
    _stderrSubscriptions.add(
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_errors.add),
    );
    _lineSubscriptions.add(
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleWireMessage, onError: _errors.add),
    );
    final hello = _hello.stream.first;
    _sendWire({
      'version': 1,
      'type': 'hello',
      'bridgeId': bridgeId,
      'lastAck': _lastAck,
    });
    await hello.timeout(const Duration(seconds: 5));
  }

  void _handleWireMessage(String line) {
    final wire = jsonDecode(line) as Map<String, dynamic>;
    switch (wire['type']) {
      case 'hello':
        _hello.add(null);
      case 'output':
        final sequence = wire['sequence'] as int;
        final data = wire['data'];
        if (!_seenSequences.add(sequence)) replayedSequenceCount += 1;
        _incoming.add(utf8.encode('${jsonEncode(data)}\n'));
        if (!holdAcknowledgements) {
          _lastAck = sequence;
          _sendWire({'version': 1, 'type': 'ack', 'ack': sequence});
        }
      case 'error':
        _errors.add(wire['error'] ?? 'unknown bridge error');
    }
  }

  void _sendWire(Map<String, Object?> wire) {
    final process = _process;
    if (process == null) throw StateError('SSH bridge is disconnected');
    process.stdin.writeln(jsonEncode(wire));
  }

  @override
  Future<void> write(List<int> bytes) async {
    final decoded = utf8.decode(bytes).trim();
    _sendWire({
      'version': 1,
      'type': 'input',
      'bridgeId': bridgeId,
      'data': jsonDecode(decoded),
    });
    await _process!.stdin.flush();
  }

  Future<void> disconnect() async {
    final process = _process;
    _process = null;
    if (process == null) return;
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 5));
  }

  Future<void> reconnect() async {
    holdAcknowledgements = false;
    await connect();
  }

  @override
  Future<void> close() async {
    await disconnect();
    for (final subscription in _lineSubscriptions) {
      await subscription.cancel();
    }
    for (final subscription in _stderrSubscriptions) {
      await subscription.cancel();
    }
    await _hello.close();
    await _incoming.close();
    if (_errors.isNotEmpty) {
      throw StateError('SSH bridge errors: $_errors');
    }
  }
}

void main() {
  final enabled = Platform.environment['MONKEYSSH_RUN_LOCAL_SSH_E2E'] == '1';

  test(
    'ACP survives a real SSH exec channel and MonkeyMux replay',
    () async {
      final config = _SshConfig.fromEnvironment();
      expect(config.user, isNotEmpty);
      expect(config.key, isNotEmpty);
      expect(config.bin, isNotEmpty);
      expect(config.cwd, isNotEmpty);

      final start = await config.run(
        '${_shellQuote('${config.bin}/monkeymux')} acp start '
        '--provider ${_shellQuote('MonkeySSH ACP E2E')} '
        '--command ${_shellQuote('${config.bin}/fake-acp-provider')} '
        '--cwd ${_shellQuote(config.cwd)}',
      );
      expect(start.exitCode, 0, reason: '${start.stderr}');
      final started =
          jsonDecode(start.stdout as String) as Map<String, dynamic>;
      final bridgeId = started['bridgeId'] as String;
      final transport = _SshBridgeTransport(config, bridgeId);
      await transport.connect();
      final connection = AcpJsonRpcConnection(
        transport: transport,
        defaultRequestTimeout: const Duration(seconds: 10),
      );
      final client = AcpClient(connection);
      final updates = client.updates.asBroadcastStream();
      final requests = client.serverRequests.asBroadcastStream();
      final seenKinds = <String>[];
      final replayedKinds = <String>[];
      final updateSubscription = updates.listen((notification) {
        final update = notification.update;
        seenKinds.add(update.kind);
        if (update is AcpContentChunkUpdate &&
            update.meta['replayed'] == true) {
          replayedKinds.add(update.kind);
        }
      });

      try {
        final initialization = await client.initialize();
        expect(initialization.agentInfo?.name, 'monkeyssh-fake-acp');
        await client.authenticate('fake-local');
        final session = await client.newSession(cwd: config.cwd);
        final sessionId = session.sessionId!;
        expect(
          (await client.listSessions()).sessions.single.sessionId,
          sessionId,
        );

        transport.holdAcknowledgements = true;
        final permissionRequests = requests
            .where((request) => request is AcpPermissionServerRequest)
            .cast<AcpPermissionServerRequest>()
            .asBroadcastStream();
        final firstPermission = permissionRequests.first;
        final image = updates.firstWhere(
          (notification) =>
              notification.update is AcpContentChunkUpdate &&
              (notification.update as AcpContentChunkUpdate).content
                  is AcpImageContent,
        );
        final resource = updates.firstWhere(
          (notification) =>
              notification.update is AcpContentChunkUpdate &&
              (notification.update as AcpContentChunkUpdate).content
                  is AcpResourceContent,
        );
        final prompt = client.prompt(
          sessionId: sessionId,
          content: const [AcpTextContent('/fixtures')],
        );
        await firstPermission;
        await transport.disconnect();

        final replayedPermission = permissionRequests.first;
        await transport.reconnect();
        final permission = await replayedPermission;
        expect(permission.permission.options.map((option) => option.id), [
          'allow-once',
          'allow-always',
          'reject-once',
          'reject-always',
        ]);
        await permission.select('allow-once');
        expect((await prompt).stopReason, AcpStopReason.endTurn);
        final imageContent =
            ((await image).update as AcpContentChunkUpdate).content
                as AcpImageContent;
        expect(base64Decode(imageContent.data).length, lessThan(1024));
        final resourceContent =
            ((await resource).update as AcpContentChunkUpdate).content
                as AcpResourceContent;
        expect(
          (resourceContent.resource as AcpTextResource).text.length,
          lessThan(1024),
        );
        expect(transport.replayedSequenceCount, greaterThan(0));
        expect(
          seenKinds,
          containsAll([
            'user_message_chunk',
            'agent_message_chunk',
            'agent_thought_chunk',
            'plan',
            'tool_call',
            'tool_call_update',
            'usage_update',
          ]),
        );
        expect(
          seenKinds.where((kind) => kind == 'agent_message_chunk').length,
          greaterThanOrEqualTo(3),
        );

        final slashPermission = permissionRequests.first;
        final slashResponse = updates.firstWhere(
          (notification) =>
              notification.update is AcpContentChunkUpdate &&
              (notification.update as AcpContentChunkUpdate).kind ==
                  'agent_message_chunk' &&
              (notification.update as AcpContentChunkUpdate).content
                  is AcpTextContent &&
              ((notification.update as AcpContentChunkUpdate).content
                          as AcpTextContent)
                      .text ==
                  'bridge-ok',
        );
        final slashPrompt = client.prompt(
          sessionId: sessionId,
          content: const [AcpTextContent('/echo bridge-ok')],
        );
        await (await slashPermission).select('allow-once');
        expect((await slashPrompt).stopReason, AcpStopReason.endTurn);
        await slashResponse;

        await client.loadSession(sessionId: sessionId, cwd: config.cwd);
        expect(
          replayedKinds,
          containsAll([
            'user_message_chunk',
            'agent_message_chunk',
            'agent_thought_chunk',
          ]),
        );
        await client.resumeSession(sessionId: sessionId, cwd: config.cwd);
        final configOptions = await client.setConfigOption(
          sessionId: sessionId,
          configId: 'responseStyle',
          value: 'detailed',
        );
        expect(
          configOptions.whereType<AcpSelectConfigOption>().single.currentValue,
          'detailed',
        );

        final thought = updates.firstWhere(
          (notification) => notification.update.kind == 'agent_thought_chunk',
        );
        final waitingPrompt = client.prompt(
          sessionId: sessionId,
          content: const [AcpTextContent('/wait')],
        );
        await thought;
        await client.cancel(sessionId);
        expect((await waitingPrompt).stopReason, AcpStopReason.cancelled);
        await client.closeSession(sessionId);
        expect(transport.errors, isEmpty);
      } finally {
        await updateSubscription.cancel();
        await client.close();
        final stop = await config.run(
          '${_shellQuote('${config.bin}/monkeymux')} acp stop '
          '${_shellQuote(bridgeId)}',
        );
        expect(stop.exitCode, 0, reason: '${stop.stderr}');
      }
    },
    skip: enabled ? false : _skipReason,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
