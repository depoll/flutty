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
        buildAgentToolCommand(
          AgentLaunchTool.copilotCli,
          startInYoloMode: true,
        ),
        'copilot --yolo',
      );
      expect(
        buildAgentToolCommand(AgentLaunchTool.codex, startInYoloMode: true),
        'codex --yolo',
      );
      expect(
        buildAgentToolCommand(AgentLaunchTool.openCode, startInYoloMode: true),
        r'OPENCODE_PERMISSION="{\"*\":\"allow\"}" opencode',
      );
      expect(
        buildAgentToolCommand(AgentLaunchTool.geminiCli, startInYoloMode: true),
        'gemini --yolo',
      );
    });
  });

  group('agentLaunchToolForCommandText', () {
    test('detects tools in wrapped shell commands', () {
      expect(
        agentLaunchToolForCommandText(
          r'OPENCODE_PERMISSION="{\"*\":\"allow\"}" /opt/bin/opencode -s abc',
        ),
        AgentLaunchTool.openCode,
      );
      expect(
        agentLaunchToolForCommandText('cd ~/repo && codex resume abc'),
        AgentLaunchTool.codex,
      );
    });

    test('returns null for commands without supported tools', () {
      expect(agentLaunchToolForCommandText('node ./script.js'), isNull);
      expect(agentLaunchToolForCommandText("cd '/tmp/codex' && node"), isNull);
      expect(agentLaunchToolForCommandText(''), isNull);
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
        additionalArguments: '--message "hello"',
      );

      expect(
        buildAgentLaunchCommand(preset),
        'tmux new-session -A -s \'nightly review\' -c '
        '"\$HOME/src/app" -x 160 -y 48 \'codex --message "hello"\' '
        r'\; set-option -g focus-events on',
      );
    });

    test('ignores tmux flags when no tmux session is configured', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        tmuxExtraFlags: '-x 160 -y 48',
        additionalArguments: '--message "hello"',
      );

      expect(buildAgentLaunchCommand(preset), 'codex --message "hello"');
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
          '-x 160 -y 48 \'gemini\' '
          r'\; set-option -g focus-events on',
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
        "tmux new-session -A -s 'nightly review' -n 'review window' "
        r"'codex' \; set-option -g focus-events on",
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
        r"tmux new-session -A -s 'copilot' 'copilot' \; set status off \; set-option -g focus-events on",
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
        '"\$HOME/work" \'opencode\' '
        r'\; set-option -g focus-events on',
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
        r'cd "$HOME/project" && codex --yolo',
      );
    });

    test('normalizes existing codex yolo aliases', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        additionalArguments: '--ask-for-approval never --model gpt-5.4',
      );

      expect(
        buildAgentLaunchCommand(preset, startInYoloMode: true),
        'codex --yolo --model gpt-5.4',
      );
    });

    test(
      'replaces conflicting codex approval and sandbox arguments in yolo mode',
      () {
        const preset = AgentLaunchPreset(
          tool: AgentLaunchTool.codex,
          additionalArguments:
              '--ask-for-approval on-request --sandbox workspace-write --model gpt-5.4',
        );

        expect(
          buildAgentLaunchCommand(preset, startInYoloMode: true),
          'codex --yolo --model gpt-5.4',
        );
      },
    );

    test(
      'rebuilds opencode in yolo mode with an allow-all permission override',
      () {
        const preset = AgentLaunchPreset(
          tool: AgentLaunchTool.openCode,
          workingDirectory: '~/project',
        );

        expect(
          buildAgentLaunchCommand(preset, startInYoloMode: true),
          r'cd "$HOME/project" && OPENCODE_PERMISSION="{\"*\":\"allow\"}" opencode',
        );
      },
    );
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

    test('command lookup resolves bare names, paths, and argv tokens', () {
      expect(
        agentLaunchToolForCommandName('claude'),
        AgentLaunchTool.claudeCode,
      );
      expect(
        agentLaunchToolForCommandName('/opt/homebrew/bin/codex'),
        AgentLaunchTool.codex,
      );
      expect(
        agentLaunchToolForCommandName(
          r'C:\Users\demo\AppData\Local\Programs\opencode.exe',
        ),
        AgentLaunchTool.openCode,
      );
      expect(
        agentLaunchToolForCommandName('gemini --yolo'),
        AgentLaunchTool.geminiCli,
      );
      expect(agentLaunchToolForCommandName('vim'), isNull);
      expect(agentLaunchToolForCommandName(''), isNull);
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
      for (final tool in AgentLaunchTool.values) {
        expect(
          tool.supportsYoloMode,
          isTrue,
          reason: '${tool.name} should support yolo mode',
        );
      }
    });
  });

  test('fromJson falls back to claudeCode for unknown tool name', () {
    final preset = AgentLaunchPreset.fromJson({'tool': 'unknownTool'});
    expect(preset.tool, AgentLaunchTool.claudeCode);
  });
}
