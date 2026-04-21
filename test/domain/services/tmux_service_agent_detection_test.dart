import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
  group('buildAgentToolDetectionCommand', () {
    test('runs an interactive instance of the user\'s shell', () {
      // The whole point of the rewrite: invoke `\$SHELL -ic`, falling
      // back to /bin/sh, so PATH additions from ~/.zshrc / ~/.bashrc
      // are picked up. SSH exec channels otherwise only see login
      // profiles and miss tools like `claude` that npm-global users
      // expose from rc files.
      final command = buildAgentToolDetectionCommand();
      expect(command, contains(r'SH="${SHELL:-/bin/sh}"'));
      expect(command, contains(r'"$SH" -ic '));
    });

    test('loops per-binary so it works on POSIX-strict shells (dash)', () {
      // dash and other strict POSIX shells reject `command -v a b c`
      // and print nothing; a per-binary loop avoids that pitfall.
      final command = buildAgentToolDetectionCommand();
      expect(command, contains('for c in '));
      expect(command, contains(r'command -v "$c"'));
    });

    test('queries every supported agent CLI', () {
      final command = buildAgentToolDetectionCommand();
      for (final tool in AgentLaunchTool.values) {
        expect(
          command,
          contains(tool.commandName),
          reason: 'detection command must look up ${tool.commandName}',
        );
      }
    });

    test('tolerates missing binaries without failing the outer shell', () {
      final command = buildAgentToolDetectionCommand();
      // 2>/dev/null suppresses noisy "not found" messages from rc files
      // and the inner shell; `|| true` keeps the exit status clean so
      // the SSH exec channel does not surface a misleading error.
      expect(command, contains('2>/dev/null'));
      expect(command, endsWith('|| true'));
    });
  });

  group('parseInstalledAgentTools', () {
    test('returns empty for empty input', () {
      expect(parseInstalledAgentTools(''), isEmpty);
      expect(parseInstalledAgentTools('   \n  \n'), isEmpty);
    });

    test('parses absolute paths to known CLI binaries', () {
      const output =
          '/opt/homebrew/bin/claude\n'
          '/usr/local/bin/codex\n'
          '/Users/me/.local/bin/aider\n';
      expect(parseInstalledAgentTools(output), {
        AgentLaunchTool.claudeCode,
        AgentLaunchTool.codex,
        AgentLaunchTool.aider,
      });
    });

    test('detects claude installed in ~/.local/bin (the regression case)', () {
      // Reproduces the user-reported regression: claude lives in
      // ~/.local/bin, which is added to PATH from ~/.zshrc rather
      // than ~/.zprofile. The interactive-shell command builder
      // resolves it; the parser must accept the path.
      const output = '/Users/depoll/.local/bin/claude\n';
      expect(parseInstalledAgentTools(output), {AgentLaunchTool.claudeCode});
    });

    test('ignores bare names (shell builtins, aliases, missing CLIs)', () {
      // `command -v` may print bare names for builtins/aliases or omit
      // unknown commands entirely. Only absolute paths should count.
      const output =
          'claude\n'
          '/usr/local/bin/copilot\n'
          'aider: not found\n';
      expect(parseInstalledAgentTools(output), {AgentLaunchTool.copilotCli});
    });

    test('ignores unknown binaries', () {
      const output = '/usr/bin/cat\n/usr/bin/grep\n/opt/bin/gemini\n';
      expect(parseInstalledAgentTools(output), {AgentLaunchTool.geminiCli});
    });

    test('handles all supported CLIs', () {
      const output =
          '/b/aider\n'
          '/b/claude\n'
          '/b/copilot\n'
          '/b/codex\n'
          '/b/gemini\n'
          '/b/opencode\n';
      expect(parseInstalledAgentTools(output), AgentLaunchTool.values.toSet());
    });

    test('tolerates trailing whitespace and CRLF line endings', () {
      const output = '/usr/local/bin/claude  \r\n/opt/bin/opencode\r\n';
      expect(parseInstalledAgentTools(output), {
        AgentLaunchTool.claudeCode,
        AgentLaunchTool.openCode,
      });
    });
  });

  group('agentToolForBinaryName', () {
    test('maps each command name back to its tool', () {
      for (final tool in AgentLaunchTool.values) {
        expect(agentToolForBinaryName(tool.commandName), tool);
      }
    });

    test('returns null for unknown binaries', () {
      expect(agentToolForBinaryName('vim'), isNull);
      expect(agentToolForBinaryName(''), isNull);
    });
  });
}
