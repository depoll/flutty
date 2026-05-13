// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
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
        startInYoloMode: true,
      );

      expect(
        command,
        "'/home/me/.monkeyssh/bin/monkey mux' attach --update-policy never "
        "--restore-yolo --cwd '~/src/it'\"'\"'s app' --name 'Codex agent' --command "
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

    test('allows one-shot run_command responses to reach server timeout', () {
      expect(
        monkeyMuxOneShotResponseTimeoutForTesting(const <String, Object?>{
          'type': 'run_command',
        }),
        const Duration(seconds: 25),
      );
      expect(
        monkeyMuxOneShotResponseTimeoutForTesting(const <String, Object?>{
          'type': 'list_windows',
        }),
        const Duration(seconds: 10),
      );
    });

    test('includes terminal dimensions for window selection requests', () {
      expect(
        monkeyMuxTerminalWindowMetricFieldsForTesting((
          columns: 100,
          rows: 32,
          pixelWidth: 1200,
          pixelHeight: 1600,
        )),
        const <String, Object?>{
          'width': 100,
          'height': 32,
          'pixelWidth': 1200,
          'pixelHeight': 1600,
        },
      );
      expect(
        monkeyMuxTerminalWindowMetricFieldsForTesting((
          columns: 100,
          rows: 32,
          pixelWidth: 0,
          pixelHeight: 0,
        )),
        const <String, Object?>{'width': 100, 'height': 32},
      );
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

  group('applyMonkeyMuxAgentSessionMetadataForTesting', () {
    test('applies live Copilot session titles by pane pid', () {
      const window = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Copilot CLI',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Copilot CLI',
      );

      final windows = applyMonkeyMuxAgentSessionMetadataForTesting(
        const [window],
        const {
          42: (sessionId: 'session-1', title: 'Implement MonkeyMux refresh'),
        },
        refreshedPanePids: const {42},
      );

      expect(windows.single.activeAgentSessionId, 'session-1');
      expect(windows.single.agentSessionTitle, 'Implement MonkeyMux refresh');
      expect(windows.single.displayTitle, 'Implement MonkeyMux refresh');
    });

    test('clears stale Copilot session titles after a refreshed miss', () {
      const window = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Copilot CLI',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Copilot CLI',
        activeAgentSessionId: 'stale-session',
        agentSessionTitle: 'Stale Copilot session',
      );

      final windows = applyMonkeyMuxAgentSessionMetadataForTesting(
        const [window],
        const {},
        refreshedPanePids: const {42},
      );

      expect(windows.single.activeAgentSessionId, isNull);
      expect(windows.single.agentSessionTitle, isNull);
      expect(windows.single.displayTitle, 'Copilot CLI');
    });

    test('keeps existing Copilot metadata when pane was not refreshed', () {
      const window = TmuxWindow(
        index: 1,
        id: '@7',
        panePid: 42,
        name: 'Copilot CLI',
        isActive: true,
        currentCommand: 'copilot',
        paneTitle: 'Copilot CLI',
        activeAgentSessionId: 'session-1',
        agentSessionTitle: 'Current Copilot session',
      );

      final windows = applyMonkeyMuxAgentSessionMetadataForTesting(const [
        window,
      ], const {});

      expect(windows.single.activeAgentSessionId, 'session-1');
      expect(windows.single.agentSessionTitle, 'Current Copilot session');
    });
  });
}
