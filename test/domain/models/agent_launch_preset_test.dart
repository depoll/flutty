// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';

void main() {
  group('buildAgentToolCommand', () {
    test('adds yolo flags for supported tools', () {
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.claudeCode,
          startInYoloMode: true,
        ),
        'claude --dangerously-skip-permissions',
      );
      expect(
        buildAgentToolCommand(AgentLaunchTool.codex, startInYoloMode: true),
        'codex --approval-mode never',
      );
      expect(
        buildAgentToolCommand(AgentLaunchTool.geminiCli, startInYoloMode: true),
        'gemini --yolo',
      );
      expect(
        buildAgentToolCommand(AgentLaunchTool.aider, startInYoloMode: true),
        'aider --yes-always',
      );
    });

    test('leaves unsupported tools unchanged in yolo mode', () {
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.copilotCli,
          startInYoloMode: true,
        ),
        'copilot',
      );
      expect(
        buildAgentToolCommand(AgentLaunchTool.openCode, startInYoloMode: true),
        'opencode',
      );
    });
  });

  group('buildAgentLaunchCommand', () {
    test('builds a working-directory command without tmux', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.claudeCode,
        workingDirectory: '~/src/app',
        additionalArguments: '--resume',
      );

      expect(
        buildAgentLaunchCommand(preset),
        r'cd "$HOME/src/app" && claude --resume',
      );
    });

    test('builds a tmux command with quoted values', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/src/app',
        tmuxSessionName: 'nightly review',
        tmuxExtraFlags: '-x 160 -y 48',
        additionalArguments: '--yes-always',
      );

      expect(
        buildAgentLaunchCommand(preset),
        'tmux new-session -A -s \'nightly review\' -c '
        '"\$HOME/src/app" -x 160 -y 48 \'codex --yes-always\'',
      );
    });

    test('ignores tmux flags when no tmux session is configured', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        tmuxExtraFlags: '-x 160 -y 48',
        additionalArguments: '--yes-always',
      );

      expect(buildAgentLaunchCommand(preset), 'codex --yes-always');
    });

    test(
      'builds command for tmux with extra flags and no working directory',
      () {
        const preset = AgentLaunchPreset(
          tool: AgentLaunchTool.geminiCli,
          tmuxSessionName: 'nightly review',
          tmuxExtraFlags: '-x 160 -y 48',
        );

        expect(
          buildAgentLaunchCommand(preset),
          'tmux new-session -A -s \'nightly review\' '
          '-x 160 -y 48 \'gemini\'',
        );
      },
    );

    test('quotes tmux flag values with spaces safely', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        tmuxSessionName: 'nightly review',
        tmuxExtraFlags: '-n "review window"',
      );

      expect(
        buildAgentLaunchCommand(preset),
        "tmux new-session -A -s 'nightly review' -n 'review window' 'codex'",
      );
    });

    test('rejects tmux command separators in extra flags', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        tmuxSessionName: 'nightly review',
        tmuxExtraFlags: r'-x 160 \; set status off',
      );

      expect(
        () => buildAgentLaunchCommand(preset),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains(r'\;'),
          ),
        ),
      );
    });

    test('can disable the tmux status bar for agent sessions', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.copilotCli,
        tmuxSessionName: 'copilot',
        tmuxDisableStatusBar: true,
      );

      expect(
        buildAgentLaunchCommand(preset),
        r"tmux new-session -A -s 'copilot' 'copilot' \; set status off",
      );
    });

    test('builds command for codex tool', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/project',
      );

      expect(buildAgentLaunchCommand(preset), r'cd "$HOME/project" && codex');
    });

    test('builds command for openCode tool', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.openCode,
        workingDirectory: '~/work',
        tmuxSessionName: 'oc-session',
      );

      expect(
        buildAgentLaunchCommand(preset),
        "tmux new-session -A -s 'oc-session' -c "
        '"\$HOME/work" \'opencode\'',
      );
    });

    test('builds command for geminiCli tool', () {
      const preset = AgentLaunchPreset(tool: AgentLaunchTool.geminiCli);

      expect(buildAgentLaunchCommand(preset), 'gemini');
    });

    test('adds yolo mode to supported presets', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/project',
      );

      expect(
        buildAgentLaunchCommand(preset, startInYoloMode: true),
        r'cd "$HOME/project" && codex --approval-mode never',
      );
    });

    test('does not duplicate a yolo flag already in extra arguments', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        additionalArguments: '--approval-mode never --model gpt-5.4',
      );

      expect(
        buildAgentLaunchCommand(preset, startInYoloMode: true),
        'codex --approval-mode never --model gpt-5.4',
      );
    });

    test('replaces conflicting codex approval-mode arguments in yolo mode', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        additionalArguments: '--approval-mode auto --model gpt-5.4',
      );

      expect(
        buildAgentLaunchCommand(preset, startInYoloMode: true),
        'codex --approval-mode never --model gpt-5.4',
      );
    });
  });

  test('round-trips preset json', () {
    const preset = AgentLaunchPreset(
      tool: AgentLaunchTool.copilotCli,
      workingDirectory: '~/src/flutty',
      tmuxSessionName: 'copilot',
      tmuxExtraFlags: '-x 160 -y 48',
      tmuxDisableStatusBar: true,
      additionalArguments: '--resume',
    );

    final decoded = AgentLaunchPreset.fromJson(preset.toJson());

    expect(decoded.tool, preset.tool);
    expect(decoded.workingDirectory, preset.workingDirectory);
    expect(decoded.tmuxSessionName, preset.tmuxSessionName);
    expect(decoded.tmuxExtraFlags, preset.tmuxExtraFlags);
    expect(decoded.tmuxDisableStatusBar, isTrue);
    expect(decoded.additionalArguments, preset.additionalArguments);
  });

  test('round-trips new tool enum values through json', () {
    for (final tool in [
      AgentLaunchTool.codex,
      AgentLaunchTool.openCode,
      AgentLaunchTool.geminiCli,
    ]) {
      final preset = AgentLaunchPreset(tool: tool);
      final decoded = AgentLaunchPreset.fromJson(preset.toJson());
      expect(decoded.tool, tool, reason: '${tool.name} round-trip failed');
    }
  });

  group('AgentLaunchTool presentation', () {
    test('all tools have labels', () {
      for (final tool in AgentLaunchTool.values) {
        expect(tool.label, isNotEmpty, reason: '${tool.name} missing label');
      }
    });

    test('all tools have command names', () {
      for (final tool in AgentLaunchTool.values) {
        expect(
          tool.commandName,
          isNotEmpty,
          reason: '${tool.name} missing commandName',
        );
      }
    });

    test('new tool labels are correct', () {
      expect(AgentLaunchTool.codex.label, 'Codex');
      expect(AgentLaunchTool.openCode.label, 'OpenCode');
      expect(AgentLaunchTool.geminiCli.label, 'Gemini CLI');
    });

    test('new tool command names are correct', () {
      expect(AgentLaunchTool.codex.commandName, 'codex');
      expect(AgentLaunchTool.openCode.commandName, 'opencode');
      expect(AgentLaunchTool.geminiCli.commandName, 'gemini');
    });

    test('supportsResume returns true for all tools', () {
      for (final tool in AgentLaunchTool.values) {
        expect(
          tool.supportsResume,
          isTrue,
          reason: '${tool.name} should support resume',
        );
      }
    });

    test('supportsYoloMode is only true for supported tools', () {
      expect(AgentLaunchTool.claudeCode.supportsYoloMode, isTrue);
      expect(AgentLaunchTool.aider.supportsYoloMode, isTrue);
      expect(AgentLaunchTool.codex.supportsYoloMode, isTrue);
      expect(AgentLaunchTool.geminiCli.supportsYoloMode, isTrue);
      expect(AgentLaunchTool.copilotCli.supportsYoloMode, isFalse);
      expect(AgentLaunchTool.openCode.supportsYoloMode, isFalse);
    });
  });

  test('fromJson falls back to claudeCode for unknown tool name', () {
    final preset = AgentLaunchPreset.fromJson({'tool': 'unknownTool'});
    expect(preset.tool, AgentLaunchTool.claudeCode);
  });
}
