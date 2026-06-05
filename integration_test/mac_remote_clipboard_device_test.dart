import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/domain/services/remote_clipboard_sync_service.dart';

const _testHost = String.fromEnvironment('TEST_SSH_HOST');
const _testPort = int.fromEnvironment('TEST_SSH_PORT');
const _testUsername = String.fromEnvironment('TEST_SSH_USERNAME');
const _testPrivateKeyBase64 = String.fromEnvironment(
  'TEST_SSH_PRIVATE_KEY_B64',
);
const _hasMacRemoteClipboardConfig =
    _testHost != '' &&
    _testPort > 0 &&
    _testUsername != '' &&
    _testPrivateKeyBase64 != '';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Mac remote clipboard commands work with device clipboard APIs',
    (tester) async {
      final client = await _connectClient();
      addTearDown(client.close);

      const localText = 'device-local-copy';
      await Clipboard.setData(const ClipboardData(text: localText));
      final writeSession = await client.execute(
        RemoteClipboardSyncService.buildWriteCommand(localText),
      );
      final writeOutput = await _drainSession(writeSession);
      expect(
        RemoteClipboardSyncService.outputIndicatesUnsupported(writeOutput),
        isFalse,
      );
      expect(
        RemoteClipboardSyncService.outputIndicatesFailure(writeOutput),
        isFalse,
      );

      final remoteReadback = await _readRemoteClipboard(client);
      expect(remoteReadback, localText);

      const remoteText = 'remote-mac-copy';
      final remoteWriteSession = await client.execute(
        RemoteClipboardSyncService.buildWriteCommand(remoteText),
      );
      final remoteWriteOutput = await _drainSession(remoteWriteSession);
      expect(
        RemoteClipboardSyncService.outputIndicatesUnsupported(
          remoteWriteOutput,
        ),
        isFalse,
      );
      expect(
        RemoteClipboardSyncService.outputIndicatesFailure(remoteWriteOutput),
        isFalse,
      );
      final readback = await _readRemoteClipboard(client);
      expect(readback, remoteText);

      await Clipboard.setData(ClipboardData(text: readback));
      final localClipboard = await Clipboard.getData(Clipboard.kTextPlain);
      expect(localClipboard?.text, remoteText);
    },
    skip: !_hasMacRemoteClipboardConfig,
  );
}

Future<SSHClient> _connectClient() async {
  final socket = await SSHSocket.connect(_testHost, _testPort);
  final privateKey = utf8.decode(base64Decode(_testPrivateKeyBase64));
  return SSHClient(
    socket,
    username: _testUsername,
    onVerifyHostKey: (_, _) => true,
    identities: SSHKeyPair.fromPem(privateKey),
  );
}

Future<String> _runCommand(SSHClient client, String command) async {
  final session = await client.execute(command);
  return _drainSession(session);
}

Future<String> _readRemoteClipboard(SSHClient client) async {
  final readOutput = await _runCommand(
    client,
    RemoteClipboardSyncService.buildReadCommand(),
  );
  final parsed = RemoteClipboardSyncService.parseReadOutput(readOutput);
  expect(parsed.status, RemoteClipboardReadStatus.supported);
  return parsed.text;
}

Future<String> _drainSession(SSHSession session) async {
  final stdout = StringBuffer();
  final stderr = StringBuffer();
  final stdoutFuture = session.stdout
      .cast<List<int>>()
      .transform(utf8.decoder)
      .forEach(stdout.write);
  final stderrFuture = session.stderr
      .cast<List<int>>()
      .transform(utf8.decoder)
      .forEach(stderr.write);
  await Future.wait<void>([stdoutFuture, stderrFuture, session.done]);
  return stdout.toString().isNotEmpty ? stdout.toString() : stderr.toString();
}
