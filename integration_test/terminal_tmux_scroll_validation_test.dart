// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/presentation/widgets/monkey_terminal_view.dart';
import 'package:monkeyssh/presentation/widgets/terminal_pinch_zoom_gesture_handler.dart';
import 'package:xterm/xterm.dart';

const _tmuxSessionName = 'flutty-touch-scroll';
const _sshPort = String.fromEnvironment('FLUTTY_SCROLL_SSH_PORT');
const _sshUser = String.fromEnvironment('FLUTTY_SCROLL_SSH_USER');
const _sshPrivateKeyBase64 = String.fromEnvironment(
  'FLUTTY_SCROLL_SSH_KEY_B64',
);
const _tmuxBinary = String.fromEnvironment(
  'FLUTTY_SCROLL_TMUX_BIN',
  defaultValue: '/Users/depoll/homebrew/bin/tmux',
);

String get _deviceReachableHost =>
    Platform.isAndroid ? '10.0.2.2' : '127.0.0.1';

int get _parsedSshPort => int.parse(_sshPort);

String get _privateKeyPem => utf8.decode(base64Decode(_sshPrivateKeyBase64));

Future<SSHClient> _openSshClient() async {
  final socket = await SSHSocket.connect(_deviceReachableHost, _parsedSshPort);
  final client = SSHClient(
    socket,
    username: _sshUser,
    identities: SSHKeyPair.fromPem(_privateKeyPem),
    disableHostkeyVerification: true,
  );
  await client.authenticated;
  return client;
}

Future<String> _runRemoteCommand(String command) async {
  final client = await _openSshClient();
  try {
    final session = await client.execute(command);
    final stdout = await utf8.decoder.bind(session.stdout).join();
    await session.done;
    return stdout.trim();
  } finally {
    client.close();
  }
}

Future<void> _prepareTmuxSession() async {
  const sendKeysCommand =
      '$_tmuxBinary send-keys -t $_tmuxSessionName '
      r'''"for i in $(seq 1 400); do printf 'LINE %04d\n' \"$i\"; done"'''
      ' Enter';
  final setupCommand = [
    '$_tmuxBinary kill-session -t $_tmuxSessionName 2>/dev/null || true',
    '$_tmuxBinary new-session -d -s $_tmuxSessionName',
    '$_tmuxBinary set-option -t $_tmuxSessionName -g mouse on',
    sendKeysCommand,
  ].join('; ');
  await _runRemoteCommand(setupCommand);
}

Future<void> _killTmuxSession() async {
  await _runRemoteCommand(
    '$_tmuxBinary kill-session -t $_tmuxSessionName 2>/dev/null || true',
  );
}

Future<void> _waitForRemoteCondition(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 300),
  String? description,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (await predicate()) {
      return;
    }
    await Future<void>.delayed(step);
  }
  fail(description ?? 'Timed out waiting for remote condition');
}

Future<void> _waitForLocalCondition(
  WidgetTester tester,
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 20),
  Duration step = const Duration(milliseconds: 100),
  String? description,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(step);
    if (predicate()) {
      return;
    }
  }
  fail(description ?? 'Timed out waiting for local condition');
}

class _TerminalHarness extends StatelessWidget {
  const _TerminalHarness({required this.terminal});

  final Terminal terminal;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: TerminalPinchZoomGestureHandler(
        child: MonkeyTerminalView(
          terminal,
          autofocus: true,
          hardwareKeyboardOnly: true,
          touchScrollToTerminal: true,
          padding: const EdgeInsets.all(8),
        ),
      ),
    ),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('touch drag scrolls inside tmux', (tester) async {
    expect(_sshPort, isNotEmpty);
    expect(_sshUser, isNotEmpty);
    expect(_sshPrivateKeyBase64, isNotEmpty);

    await tester.binding.setSurfaceSize(const Size(430, 932));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _prepareTmuxSession();
    addTearDown(_killTmuxSession);

    final client = await _openSshClient();
    final shell = await client.shell(
      pty: const SSHPtyConfig(width: 120, height: 40),
    );
    final terminal = Terminal(maxLines: 10000);
    final emittedOutput = <String>[];

    final stdoutSubscription = shell.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen(terminal.write);
    final stderrSubscription = shell.stderr
        .cast<List<int>>()
        .transform(utf8.decoder)
        .listen(terminal.write);

    terminal
      ..onOutput = (data) {
        emittedOutput.add(data);
        shell.write(utf8.encode(data == '\n' ? '\r' : data));
      }
      ..onResize = shell.resizeTerminal;

    addTearDown(() async {
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      shell.close();
      client.close();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 300));
    });

    await tester.pumpWidget(_TerminalHarness(terminal: terminal));
    await tester.pump(const Duration(seconds: 2));

    shell.write(utf8.encode('$_tmuxBinary attach -t $_tmuxSessionName\r'));

    await _waitForRemoteCondition(
      () async =>
          int.parse(
            await _runRemoteCommand(
              '$_tmuxBinary list-clients -t $_tmuxSessionName 2>/dev/null | wc -l',
            ),
          ) >=
          1,
      description: 'Timed out waiting for tmux client attachment',
    );

    await _waitForLocalCondition(
      tester,
      () => terminal.mouseMode.reportScroll,
      description: 'Timed out waiting for local tmux mouse reporting',
    );

    expect(
      await _runRemoteCommand(
        '$_tmuxBinary display-message -p -t $_tmuxSessionName \'#{pane_in_mode}\'',
      ),
      '0',
    );

    await tester.drag(find.byType(MonkeyTerminalView), const Offset(0, 320));
    await tester.pump(const Duration(milliseconds: 500));

    final emittedOutputText = emittedOutput.join();
    expect(
      emittedOutputText,
      contains('\x1b[<64;'),
      reason:
          'Touch drag did not emit an SGR wheel-up sequence after tmux '
          'enabled mouse reporting: $emittedOutputText',
    );

    await _waitForRemoteCondition(
      () async =>
          await _runRemoteCommand(
            '$_tmuxBinary display-message -p -t $_tmuxSessionName \'#{pane_in_mode}\'',
          ) ==
          '1',
      description: 'Timed out waiting for tmux to enter copy mode after drag',
    );
  });
}
