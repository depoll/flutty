// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';

void main() {
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
        tool: AgentLaunchTool.aider,
        workingDirectory: '~/src/app',
        tmuxSessionName: 'nightly review',
        additionalArguments: '--yes-always',
      );

      expect(
        buildAgentLaunchCommand(preset),
        'tmux new-session -A -s \'nightly review\' -c "\$HOME/src/app" \'aider --yes-always\'',
      );
    });
  });

  test('round-trips preset json', () {
    const preset = AgentLaunchPreset(
      tool: AgentLaunchTool.copilotCli,
      workingDirectory: '~/src/flutty',
      tmuxSessionName: 'copilot',
      additionalArguments: '--resume',
    );

    final decoded = AgentLaunchPreset.fromJson(preset.toJson());

    expect(decoded.tool, preset.tool);
    expect(decoded.workingDirectory, preset.workingDirectory);
    expect(decoded.tmuxSessionName, preset.tmuxSessionName);
    expect(decoded.additionalArguments, preset.additionalArguments);
  });
}
