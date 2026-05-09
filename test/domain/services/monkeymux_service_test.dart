// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/services/monkeymux_service.dart';

void main() {
  group('RemoteMuxBackendPresentation', () {
    test('parses stable storage values', () {
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('auto'),
        RemoteMuxBackend.auto,
      );
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('monkey_mux'),
        RemoteMuxBackend.monkeyMux,
      );
      expect(
        RemoteMuxBackendPresentation.fromStorageValue('tmux'),
        RemoteMuxBackend.tmux,
      );
      expect(RemoteMuxBackendPresentation.fromStorageValue(''), isNull);
    });

    test('keeps tmux extra flags on tmux startup', () {
      expect(
        resolveRemoteMuxBackendForStartup(
          storedBackend: 'auto',
          tmuxExtraFlags: '-f ~/.tmux.conf',
        ),
        RemoteMuxBackend.tmux,
      );
      expect(
        resolveRemoteMuxBackendForStartup(
          storedBackend: 'auto',
          tmuxExtraFlags: '',
        ),
        RemoteMuxBackend.auto,
      );
    });
  });

  group('buildMonkeyMuxAttachCommand', () {
    test('puts flags before the session and shell-quotes values', () {
      final command = buildMonkeyMuxAttachCommand(
        executablePath: '/home/me/.monkeyssh/bin/monkey mux',
        sessionName: "work'space",
        workingDirectory: "~/src/it's app",
        windowName: 'Codex agent',
        launchCommand: "codex --model 'gpt-5.4'",
        serverUpdatePolicy: MonkeyMuxServerUpdatePolicy.never,
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkey mux' attach --update-policy never --cwd "
        "'~/src/it'\"'\"'s app' --name 'Codex agent' --command "
        "'codex --model '\"'\"'gpt-5.4'\"'\"'' 'work'\"'\"'space'",
      );
    });
  });

  group('MonkeyMuxServerStatus', () {
    test('detects version mismatches and shutdown capability', () {
      const status = MonkeyMuxServerStatus(
        version: '0.1.13',
        capabilities: {'window-list', 'shutdown'},
      );

      expect(status.supportsShutdown, isTrue);
      expect(status.needsUpdate('0.1.13'), isFalse);
      expect(status.needsUpdate('0.1.14'), isTrue);
    });
  });

  group('MonkeyMux control responses', () {
    test('parse foreground attach state', () {
      final hasForegroundClient = parseMonkeyMuxHasForegroundClientForTesting(
        '{"type":"attach_state","status":"ok","hasForegroundClient":true}',
      );

      expect(hasForegroundClient, isTrue);
    });
  });

  group('parseMonkeyMuxWindowSnapshotForTesting', () {
    test('maps helper agentTool metadata onto tmux windows', () {
      final window = parseMonkeyMuxWindowSnapshotForTesting({
        'id': '@1',
        'index': 0,
        'name': 'Gemini CLI',
        'active': true,
        'currentCommand': 'node',
        'panePid': 1234,
        'agentTool': 'gemini',
      });

      expect(window, isNotNull);
      expect(window!.foregroundAgentTool, AgentLaunchTool.geminiCli);
    });
  });
}
