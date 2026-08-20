// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/models/remote_multiplexer.dart';

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
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.antigravity,
          startInYoloMode: true,
        ),
        'agy --dangerously-skip-permissions',
      );
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.cursorAgent,
          startInYoloMode: true,
        ),
        'cursor-agent --force',
      );
    });

    test(
      'places profiles before terminal modes and preserves YOLO settings',
      () {
        expect(
          buildAgentToolCommand(
            AgentLaunchTool.hermes,
            launchProfile: 'work',
            startInYoloMode: true,
          ),
          "hermes --profile 'work' --yolo",
        );
        expect(
          buildAgentToolCommand(
            AgentLaunchTool.openclaw,
            launchProfile: 'ops',
            startInYoloMode: true,
          ),
          "openclaw --profile 'ops' tui",
        );
        expect(
          () => buildAgentToolCommand(
            AgentLaunchTool.claudeCode,
            launchProfile: 'unsupported',
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('buildAgentResumeCommand', () {
    test('adds yolo flags for supported resume commands', () {
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.claudeCode,
          'claude-session',
          startInYoloMode: true,
        ),
        "claude --dangerously-skip-permissions --resume 'claude-session'",
      );
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.copilotCli,
          'copilot-session',
          startInYoloMode: true,
        ),
        "copilot --yolo --resume 'copilot-session'",
      );
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.codex,
          'codex-session',
          startInYoloMode: true,
        ),
        "codex --yolo resume 'codex-session'",
      );
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.geminiCli,
          'gemini-session',
          startInYoloMode: true,
        ),
        "gemini --yolo --resume 'gemini-session'",
      );
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.openCode,
          'opencode-session',
          startInYoloMode: true,
        ),
        r"""OPENCODE_PERMISSION="{\"*\":\"allow\"}" opencode --session 'opencode-session'""",
      );
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.antigravity,
          'agy-session',
          startInYoloMode: true,
        ),
        "agy --dangerously-skip-permissions --conversation 'agy-session'",
      );
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.cursorAgent,
          'cursor-session',
          startInYoloMode: true,
        ),
        "cursor-agent --force --resume 'cursor-session'",
      );
    });

    test('preserves OpenCode continue resume command in yolo mode', () {
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.openCode,
          '_continue',
          startInYoloMode: true,
        ),
        r'OPENCODE_PERMISSION="{\"*\":\"allow\"}" opencode --continue',
      );
    });

    test('preserves Antigravity continue resume command in yolo mode', () {
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.antigravity,
          '_continue',
          startInYoloMode: true,
        ),
        'agy --dangerously-skip-permissions --continue',
      );
    });

    test('preserves Cursor Agent continue resume command in yolo mode', () {
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.cursorAgent,
          '_continue',
          startInYoloMode: true,
        ),
        'cursor-agent --force --continue',
      );
    });

    test('builds Cursor Agent resume by chat id', () {
      expect(
        buildAgentResumeCommand(AgentLaunchTool.cursorAgent, 'chat-42'),
        "cursor-agent --resume 'chat-42'",
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
      expect(
        agentLaunchToolForCommandText('cursor-agent --resume abc'),
        AgentLaunchTool.cursorAgent,
      );
      expect(
        agentLaunchToolForCommandText('cd ~/repo && cursor-agent --force'),
        AgentLaunchTool.cursorAgent,
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

    test('keeps MonkeyMux agent sessions as plain agent commands', () {
      const preset = AgentLaunchPreset(
        tool: AgentLaunchTool.codex,
        workingDirectory: '~/src/app',
        tmuxSessionName: 'nightly review',
        remoteMuxBackend: RemoteMuxBackend.monkeyMux,
        tmuxExtraFlags: '-x 160 -y 48',
        tmuxDisableStatusBar: true,
        additionalArguments: '--message "hello"',
      );

      expect(preset.usesMonkeyMuxSession, isTrue);
      expect(preset.usesTmuxSession, isFalse);
      expect(
        buildAgentLaunchCommand(preset),
        r'cd "$HOME/src/app" && codex --message "hello"',
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
    expect(decoded.effectiveRemoteMuxBackend, preset.effectiveRemoteMuxBackend);
    expect(decoded.tmuxExtraFlags, preset.tmuxExtraFlags);
    expect(decoded.tmuxDisableStatusBar, isTrue);
    expect(decoded.additionalArguments, preset.additionalArguments);
  });

  test('decodes legacy session presets as tmux', () {
    final preset = AgentLaunchPreset.fromJson({
      'tool': 'codex',
      'tmuxSessionName': 'legacy-agent',
    });

    expect(preset.remoteMuxBackend, isNull);
    expect(preset.effectiveRemoteMuxBackend, RemoteMuxBackend.tmux);
    expect(preset.usesTmuxSession, isTrue);
  });

  test('round-trips new tool enum values through json', () {
    for (final tool in [
      AgentLaunchTool.codex,
      AgentLaunchTool.openCode,
      AgentLaunchTool.geminiCli,
      AgentLaunchTool.antigravity,
      AgentLaunchTool.cursorAgent,
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
      expect(AgentLaunchTool.antigravity.label, 'Antigravity');
      expect(AgentLaunchTool.cursorAgent.label, 'Cursor Agent');
    });

    test('new tool command names are correct', () {
      expect(AgentLaunchTool.codex.commandName, 'codex');
      expect(AgentLaunchTool.openCode.commandName, 'opencode');
      expect(AgentLaunchTool.geminiCli.commandName, 'gemini');
      expect(AgentLaunchTool.antigravity.commandName, 'agy');
      expect(AgentLaunchTool.cursorAgent.commandName, 'cursor-agent');
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
        agentLaunchToolForCommandName(
          r'C:\Users\demo\AppData\Roaming\npm\copilot.cmd',
        ),
        AgentLaunchTool.copilotCli,
      );
      expect(
        agentLaunchToolForCommandName('gemini --yolo'),
        AgentLaunchTool.geminiCli,
      );
      expect(
        agentLaunchToolForCommandName('gemini-cli'),
        AgentLaunchTool.geminiCli,
      );
      expect(agentLaunchToolForCommandName('codex-cli'), AgentLaunchTool.codex);
      expect(
        agentLaunchToolForCommandName('agy --dangerously-skip-permissions'),
        AgentLaunchTool.antigravity,
      );
      expect(
        agentLaunchToolForCommandName('antigravity'),
        AgentLaunchTool.antigravity,
      );
      expect(
        agentLaunchToolForCommandName('antigravity-cli'),
        AgentLaunchTool.antigravity,
      );
      expect(
        agentLaunchToolForCommandName('cursor-agent'),
        AgentLaunchTool.cursorAgent,
      );
      expect(
        agentLaunchToolForCommandName('/Users/demo/.local/bin/cursor-agent'),
        AgentLaunchTool.cursorAgent,
      );
      expect(agentLaunchToolForCommandName('vim'), isNull);
      expect(agentLaunchToolForCommandName(''), isNull);
    });

    test('resolves the newly supported CLIs from command names', () {
      expect(
        agentLaunchToolForCommandName('claude-agent-acp'),
        AgentLaunchTool.claudeCode,
      );
      expect(agentLaunchToolForCommandName('codex-acp'), AgentLaunchTool.codex);
      expect(
        agentLaunchToolForCommandName('cursor-agent-acp'),
        AgentLaunchTool.cursorAgent,
      );
      expect(
        agentLaunchToolForCommandName('antigravity-acp'),
        AgentLaunchTool.antigravity,
      );
      expect(
        agentLaunchToolForCommandName('agy-acp'),
        AgentLaunchTool.antigravity,
      );
      expect(agentLaunchToolForCommandName('pi'), AgentLaunchTool.pi);
      expect(agentLaunchToolForCommandName('hermes'), AgentLaunchTool.hermes);
      expect(
        agentLaunchToolForCommandName('hermes-agent'),
        AgentLaunchTool.hermes,
      );
      expect(
        agentLaunchToolForCommandName('openclaw'),
        AgentLaunchTool.openclaw,
      );
      expect(
        agentLaunchToolForCommandText('openclaw tui'),
        AgentLaunchTool.openclaw,
      );
      expect(
        agentLaunchToolForCommandName('/opt/homebrew/bin/pi'),
        AgentLaunchTool.pi,
      );
      expect(agentLaunchToolForCommandName('grok'), AgentLaunchTool.grokBuild);
      expect(
        agentLaunchToolForCommandText('cd ~/repo && grok --resume abc'),
        AgentLaunchTool.grokBuild,
      );
    });

    test('builds launch commands for the newly supported CLIs', () {
      expect(buildAgentToolCommand(AgentLaunchTool.pi), 'pi');
      expect(buildAgentToolCommand(AgentLaunchTool.hermes), 'hermes');
      // OpenClaw's interactive UI lives behind the `tui` subcommand.
      expect(buildAgentToolCommand(AgentLaunchTool.openclaw), 'openclaw tui');
      expect(
        buildAgentToolCommand(AgentLaunchTool.hermes, startInYoloMode: true),
        'hermes --yolo',
      );
      // Pi exposes no YOLO flag, so the host setting must not invent one.
      expect(
        buildAgentToolCommand(AgentLaunchTool.pi, startInYoloMode: true),
        'pi',
      );
      expect(
        buildAgentToolCommand(AgentLaunchTool.openclaw, startInYoloMode: true),
        'openclaw tui',
      );
      expect(buildAgentToolCommand(AgentLaunchTool.grokBuild), 'grok');
      expect(
        buildAgentToolCommand(AgentLaunchTool.grokBuild, startInYoloMode: true),
        'grok --yolo',
      );
    });

    test('does not duplicate an explicit Hermes yolo argument', () {
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.hermes,
          additionalArguments: '--yolo --tui',
          startInYoloMode: true,
        ),
        'hermes --yolo --tui',
      );
    });

    test('normalizes explicit Grok permission arguments in yolo mode', () {
      expect(
        buildAgentToolCommand(
          AgentLaunchTool.grokBuild,
          additionalArguments: '--permission-mode ask --always-approve --trust',
          startInYoloMode: true,
        ),
        'grok --yolo --trust',
      );
    });

    test('wraps only MonkeyMux Pi commands with exact identity support', () {
      expect(
        buildMonkeyMuxAgentToolCommand(
          AgentLaunchTool.pi,
          'pi --session-dir sessions',
        ),
        'monkeymux pi-agent --session-dir sessions',
      );
      expect(
        buildMonkeyMuxAgentToolCommand(
          AgentLaunchTool.claudeCode,
          'claude --resume session',
        ),
        'claude --resume session',
      );
    });

    test('builds resume commands for the newly supported CLIs', () {
      expect(
        buildAgentResumeCommand(AgentLaunchTool.pi, 'abc123'),
        "pi --session 'abc123'",
      );
      expect(
        buildAgentResumeCommand(AgentLaunchTool.pi, '_continue'),
        'pi --continue',
      );
      expect(
        buildAgentResumeCommand(AgentLaunchTool.hermes, '20250305_091523_a1b2'),
        "hermes --resume '20250305_091523_a1b2'",
      );
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.hermes,
          '_continue',
          startInYoloMode: true,
        ),
        'hermes --yolo --continue',
      );
      // The `tui` subcommand must stay ahead of the resume arguments.
      expect(
        buildAgentResumeCommand(AgentLaunchTool.openclaw, 'main'),
        "openclaw tui --session 'main'",
      );
      expect(
        buildAgentResumeCommand(AgentLaunchTool.openclaw, '_continue'),
        'openclaw tui',
      );
      expect(
        buildAgentResumeCommand(AgentLaunchTool.grokBuild, '019f6cb5-f7e4'),
        "grok --resume '019f6cb5-f7e4'",
      );
      expect(
        buildAgentResumeCommand(
          AgentLaunchTool.grokBuild,
          '_continue',
          startInYoloMode: true,
        ),
        'grok --yolo --resume',
      );
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

    test('supportsYoloMode reflects each CLI startup capability', () {
      // Pi has no approval layer, and OpenClaw's YOLO preset is a persisted
      // exec-policy mutation rather than a per-launch flag.
      const withoutYolo = {AgentLaunchTool.pi, AgentLaunchTool.openclaw};
      for (final tool in AgentLaunchTool.values) {
        expect(
          tool.supportsYoloMode,
          !withoutYolo.contains(tool),
          reason: '${tool.name} yolo support is misreported',
        );
      }
    });
  });

  test('fromJson rejects unknown tool names instead of rewriting them', () {
    expect(
      () => AgentLaunchPreset.fromJson({'tool': 'unknownTool'}),
      throwsA(isA<FormatException>()),
    );
    expect(AgentLaunchPreset.tryFromJson({'tool': 'unknownTool'}), isNull);
    expect(agentLaunchToolFromStorageName('codex'), AgentLaunchTool.codex);
    expect(agentLaunchToolFromStorageName('unknownTool'), isNull);
  });
}
