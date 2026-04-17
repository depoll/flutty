import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/services/tmux_service.dart';

void main() {
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
