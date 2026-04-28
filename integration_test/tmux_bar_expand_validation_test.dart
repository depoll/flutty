// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/app/app.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

const _hostLabel = 'Local tmux validation';
const _sshPort = String.fromEnvironment('FLUTTY_TMUX_BAR_SSH_PORT');
const _sshUser = String.fromEnvironment('FLUTTY_TMUX_BAR_SSH_USER');
const _sshPrivateKeyBase64 = String.fromEnvironment(
  'FLUTTY_TMUX_BAR_SSH_KEY_B64',
);
const _sshPublicKeyBase64 = String.fromEnvironment(
  'FLUTTY_TMUX_BAR_SSH_PUB_B64',
);
const _tmuxSessionName = String.fromEnvironment(
  'FLUTTY_TMUX_BAR_SESSION',
  defaultValue: 'MonkeySSH',
);
const _tmuxHandleBarKey = ValueKey<String>('tmux-handle-bar');

String get _deviceReachableHost =>
    Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 200),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }

  fail('Timed out waiting for finder: $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final binding = IntegrationTestWidgetsFlutterBinding.instance;

  testWidgets('expands the tmux bar on device', (tester) async {
    expect(_sshPort, isNotEmpty);
    expect(_sshUser, isNotEmpty);
    expect(_sshPrivateKeyBase64, isNotEmpty);
    expect(_sshPublicKeyBase64, isNotEmpty);

    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
    }

    final container = ProviderContainer(
      overrides: [
        hostKeyPromptHandlerProvider.overrideWithValue(
          (_) async => HostKeyTrustDecision.trust,
        ),
      ],
    );
    addTearDown(container.dispose);

    final db = container.read(databaseProvider);
    await db.customStatement('DELETE FROM known_hosts;');
    await db.customStatement('DELETE FROM hosts;');
    await db.customStatement('DELETE FROM ssh_keys;');

    final keyId = await container
        .read(keyRepositoryProvider)
        .insert(
          SshKeysCompanion.insert(
            name: 'Temporary tmux validation key',
            keyType: 'ed25519',
            publicKey: utf8.decode(base64Decode(_sshPublicKeyBase64)),
            privateKey: utf8.decode(base64Decode(_sshPrivateKeyBase64)),
          ),
        );

    final hostId = await container
        .read(hostRepositoryProvider)
        .insert(
          HostsCompanion.insert(
            label: _hostLabel,
            hostname: _deviceReachableHost,
            port: Value(int.parse(_sshPort)),
            username: _sshUser,
            keyId: Value(keyId),
            autoConnectRequiresConfirmation: const Value(false),
            tmuxSessionName: const Value(_tmuxSessionName),
          ),
        );

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const FluttyApp()),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final hostRow = find.byKey(ValueKey('home-host-$hostId'));
    await _pumpUntilFound(tester, hostRow);

    await tester.tap(hostRow);
    await tester.pump();

    await _pumpUntilFound(
      tester,
      find.byType(TerminalScreen),
      timeout: const Duration(seconds: 20),
    );
    final handleBar = find.byKey(_tmuxHandleBarKey);
    await _pumpUntilFound(tester, handleBar);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await binding.takeScreenshot('tmux-bar-collapsed');

    await tester.tap(handleBar);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await _pumpUntilFound(
      tester,
      find.text('New Window'),
      timeout: const Duration(seconds: 15),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text('New Window'), findsOneWidget);
    await binding.takeScreenshot('tmux-bar-expanded');
  });
}
