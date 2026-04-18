import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/host_key_prompt_handler_provider.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:xterm/xterm.dart';

const _testHost = String.fromEnvironment('TEST_SSH_HOST');
const _testPort = int.fromEnvironment('TEST_SSH_PORT');
const _testUsername = String.fromEnvironment('TEST_SSH_USERNAME');
const _testPrivateKeyBase64 = String.fromEnvironment(
  'TEST_SSH_PRIVATE_KEY_B64',
);
const _testPublicKeyBase64 = String.fromEnvironment('TEST_SSH_PUBLIC_KEY_B64');
const _testTmuxShellSession = 'monkeyssh-selection-live';
const _testTmuxCopilotSession = 'monkeyssh-selection-copilot-live';
const _hasSelectionTestConfig =
    _testHost != '' &&
    _testPort > 0 &&
    _testUsername != '' &&
    _testPrivateKeyBase64 != '' &&
    _testPublicKeyBase64 != '';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TerminalScreen long press shows overlay in a real SSH tmux session',
    (tester) async {
      final terminal = await _pumpLiveTerminalScreen(
        tester,
        tmuxSessionName: _testTmuxShellSession,
      );
      await _waitForTerminalText(
        tester,
        terminal,
        'alpha bravo',
        description: 'Timed out waiting for the live tmux session text',
      );

      final tapOffset = _tapOffsetForVisibleToken(tester, terminal, 'alpha');
      expect(tapOffset, isNotNull);

      await tester.longPressAt(tapOffset!);
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      if (overlayField.evaluate().isEmpty) {
        final terminalView = tester.widget<MonkeyTerminalView>(
          find.byType(MonkeyTerminalView),
        );
        fail(
          'No overlay after live tmux long press.\n'
          'tapOffset=$tapOffset\n'
          'terminalSelection=${terminalView.controller?.selection}\n'
          'refoundOffset=${_tapOffsetForVisibleToken(tester, terminal, 'alpha')}\n'
          'buffer:\n${_terminalBufferText(terminal)}',
        );
      }
      expect(overlayField, findsOneWidget);

      final terminalView = tester.widget<MonkeyTerminalView>(
        find.byType(MonkeyTerminalView),
      );
      expect(terminalView.controller, isNotNull);
      expect(terminalView.controller!.selection, isNull);

      final controller = tester.widget<TextField>(overlayField).controller;
      expect(controller, isNotNull);
      expect(controller!.selection.isCollapsed, isFalse);
      expect(controller.selection.textInside(controller.text), 'alpha');
    },
    skip: !_hasSelectionTestConfig,
  );

  testWidgets(
    'TerminalScreen long press shows overlay in a real SSH Copilot tmux session',
    (tester) async {
      final terminal = await _pumpLiveTerminalScreen(
        tester,
        tmuxSessionName: _testTmuxCopilotSession,
      );
      await _waitForTerminalText(
        tester,
        terminal,
        'seahorse',
        description: 'Timed out waiting for the live Copilot tmux output',
        timeout: const Duration(seconds: 40),
      );

      final tapOffset = _tapOffsetForVisibleToken(tester, terminal, 'seahorse');
      expect(tapOffset, isNotNull);

      await tester.longPressAt(tapOffset!);
      await tester.pumpAndSettle();

      final overlayField = find.byType(TextField);
      expect(overlayField, findsOneWidget);

      final terminalView = tester.widget<MonkeyTerminalView>(
        find.byType(MonkeyTerminalView),
      );
      expect(terminalView.controller, isNotNull);
      expect(terminalView.controller!.selection, isNull);

      final controller = tester.widget<TextField>(overlayField).controller;
      expect(controller, isNotNull);
      expect(controller!.selection.isCollapsed, isFalse);
      expect(controller.selection.textInside(controller.text), 'seahorse');
    },
    skip: !_hasSelectionTestConfig,
  );
}

Future<Terminal> _pumpLiveTerminalScreen(
  WidgetTester tester, {
  required String tmuxSessionName,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final encryptionService = SecretEncryptionService.forTesting();
  final hostRepository = HostRepository(db, encryptionService);
  final keyRepository = KeyRepository(db, encryptionService);

  final privateKey = utf8.decode(base64Decode(_testPrivateKeyBase64));
  final publicKey = utf8.decode(base64Decode(_testPublicKeyBase64));
  final keyId = await keyRepository.insert(
    SshKeysCompanion.insert(
      name: 'Selection SSH Test Key',
      keyType: 'ed25519',
      publicKey: publicKey,
      privateKey: privateKey,
      passphrase: const drift.Value(null),
      fingerprint: const drift.Value('selection-ssh-test'),
    ),
  );

  final hostId = await hostRepository.insert(
    HostsCompanion.insert(
      label: 'Selection SSH Test Host',
      hostname: _testHost,
      port: const drift.Value(_testPort),
      username: _testUsername,
      keyId: drift.Value(keyId),
      password: const drift.Value(null),
      tmuxSessionName: drift.Value(tmuxSessionName),
      autoConnectRequiresConfirmation: const drift.Value(false),
    ),
  );

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
  return _terminalFromView(tester);
}

Future<void> _pumpUntilConnected(WidgetTester tester) async {
  for (var i = 0; i < 120; i += 1) {
    await tester.pump(const Duration(milliseconds: 250));
    if (find.text('Connecting...').evaluate().isEmpty) {
      break;
    }
  }
  expect(find.textContaining('Failed to start shell'), findsNothing);
  expect(find.textContaining('Connection failed'), findsNothing);
}

Terminal _terminalFromView(WidgetTester tester) =>
    tester.widget<MonkeyTerminalView>(find.byType(MonkeyTerminalView)).terminal;

Offset? _tapOffsetForVisibleToken(
  WidgetTester tester,
  Terminal terminal,
  String token,
) {
  final terminalViewState = tester.state<MonkeyTerminalViewState>(
    find.byType(MonkeyTerminalView),
  );
  final renderTerminal = terminalViewState.renderTerminal;
  final firstVisibleRow = (terminal.buffer.lines.length - terminal.viewHeight)
      .clamp(0, terminal.buffer.lines.length - 1);

  for (
    var row = firstVisibleRow;
    row < terminal.buffer.lines.length;
    row += 1
  ) {
    final lineText = trimTerminalLinePadding(
      terminal.buffer.lines[row].getText(0, terminal.buffer.viewWidth),
    );
    final startColumn = lineText.indexOf(token);
    if (startColumn == -1) {
      continue;
    }

    final tapColumn = startColumn + (token.length ~/ 2);
    final cellOffset = CellOffset(tapColumn, row);
    final localOffset =
        renderTerminal.getOffset(cellOffset) +
        renderTerminal.cellSize.center(Offset.zero);
    return renderTerminal.localToGlobal(localOffset);
  }

  return null;
}

Future<void> _waitForTerminalText(
  WidgetTester tester,
  Terminal terminal,
  String expected, {
  required String description,
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 100),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(step);
    if (_terminalBufferText(terminal).contains(expected)) {
      return;
    }
  }
  fail(
    '$description\nCurrent terminal text:\n${_terminalBufferText(terminal)}',
  );
}

String _terminalBufferText(Terminal terminal) {
  final logicalLines = <StringBuffer>[];

  for (var index = 0; index < terminal.buffer.lines.length; index += 1) {
    final line = terminal.buffer.lines[index];
    final text = line.getText(0, terminal.buffer.viewWidth);
    if (line.isWrapped && logicalLines.isNotEmpty) {
      logicalLines.last.write(text);
      continue;
    }
    logicalLines.add(StringBuffer(text));
  }

  return logicalLines
      .map((line) => trimTerminalLinePadding(line.toString()))
      .join('\n');
}
