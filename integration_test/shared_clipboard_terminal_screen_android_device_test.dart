import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

const _testHost = String.fromEnvironment('TEST_SSH_HOST');
const _testPort = int.fromEnvironment('TEST_SSH_PORT');
const _testUsername = String.fromEnvironment('TEST_SSH_USERNAME');
const _testPrivateKeyBase64 = String.fromEnvironment(
  'TEST_SSH_PRIVATE_KEY_B64',
);
const _testPublicKeyBase64 = String.fromEnvironment('TEST_SSH_PUBLIC_KEY_B64');
const _hasSharedClipboardTestConfig =
    _testHost != '' &&
    _testPort > 0 &&
    _testUsername != '' &&
    _testPrivateKeyBase64 != '' &&
    _testPublicKeyBase64 != '';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'shared clipboard syncs local and remote clipboards through TerminalScreen',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepository = HostRepository(db, encryptionService);
      final keyRepository = KeyRepository(db, encryptionService);
      final settingsService = SettingsService(db);

      await settingsService.setBool(SettingKeys.sharedClipboard, value: true);

      final privateKey = utf8.decode(base64Decode(_testPrivateKeyBase64));
      final publicKey = utf8.decode(base64Decode(_testPublicKeyBase64));
      final keyId = await keyRepository.insert(
        SshKeysCompanion.insert(
          name: 'Shared Clipboard Test Key',
          keyType: 'ed25519',
          publicKey: publicKey,
          privateKey: privateKey,
          passphrase: const Value(null),
          fingerprint: const Value('test-fingerprint'),
        ),
      );

      final hostId = await hostRepository.insert(
        HostsCompanion.insert(
          label: 'Shared Clipboard Test Host',
          hostname: _testHost,
          port: const Value(_testPort),
          username: _testUsername,
          keyId: Value(keyId),
          password: const Value(null),
        ),
      );

      final client = await _connectVerifierClient();
      addTearDown(client.close);

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          secretEncryptionServiceProvider.overrideWithValue(encryptionService),
          hostKeyPromptHandlerProvider.overrideWithValue(
            (_) async => HostKeyTrustDecision.trust,
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: TerminalScreen(hostId: hostId)),
        ),
      );

      await _pumpUntilConnected(tester);

      const localText = 'local-device-copy';
      await Clipboard.setData(const ClipboardData(text: localText));
      await tester.pump(const Duration(seconds: 4));

      final remoteClipboard = await _readRemoteClipboard(client);
      expect(remoteClipboard, localText);

      const remoteText = 'remote-machine-copy';
      await _writeRemoteClipboard(client, remoteText);
      await tester.pump(const Duration(seconds: 4));

      final localClipboard = await Clipboard.getData(Clipboard.kTextPlain);
      expect(localClipboard?.text, remoteText);
    },
    skip:
        !_hasSharedClipboardTestConfig ||
        defaultTargetPlatform != TargetPlatform.android,
  );
}

Future<void> _pumpUntilConnected(WidgetTester tester) async {
  for (var i = 0; i < 60; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find.text('Connecting...').evaluate().isEmpty) {
      break;
    }
  }
  expect(find.textContaining('Failed to start shell'), findsNothing);
  expect(find.textContaining('Connection failed'), findsNothing);
}

Future<SSHClient> _connectVerifierClient() async {
  final socket = await SSHSocket.connect(_testHost, _testPort);
  final privateKey = utf8.decode(base64Decode(_testPrivateKeyBase64));
  return SSHClient(
    socket,
    username: _testUsername,
    onVerifyHostKey: (_, fingerprint) => true,
    identities: SSHKeyPair.fromPem(privateKey),
  );
}

Future<void> _writeRemoteClipboard(SSHClient client, String text) async {
  final session = await client.execute("printf %s '$text' | pbcopy");
  await _drainSession(session);
}

Future<String> _readRemoteClipboard(SSHClient client) async {
  final session = await client.execute('pbpaste');
  final output = await _drainSession(session);
  return output.trimRight();
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
