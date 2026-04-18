// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/domain/services/agent_launch_preset_service.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';

void main() {
  late AppDatabase database;
  late AgentLaunchPresetService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    service = AgentLaunchPresetService(SettingsService(database));
  });

  tearDown(() async {
    await database.close();
  });

  test('stores and loads a host preset', () async {
    const preset = AgentLaunchPreset(
      tool: AgentLaunchTool.claudeCode,
      workingDirectory: '~/src/flutty',
      tmuxSessionName: 'claude',
      tmuxExtraFlags: '-f ~/.tmux-agent.conf',
      additionalArguments: '--resume',
    );

    await service.setPresetForHost(42, preset);
    final loaded = await service.getPresetForHost(42);

    expect(loaded, isNotNull);
    expect(loaded!.tool, preset.tool);
    expect(loaded.workingDirectory, preset.workingDirectory);
    expect(loaded.tmuxSessionName, preset.tmuxSessionName);
    expect(loaded.tmuxExtraFlags, preset.tmuxExtraFlags);
    expect(loaded.additionalArguments, preset.additionalArguments);
  });

  test('deletes a stored host preset', () async {
    const preset = AgentLaunchPreset(tool: AgentLaunchTool.codex);

    await service.setPresetForHost(7, preset);
    await service.deletePresetForHost(7);

    expect(await service.getPresetForHost(7), isNull);
  });
}
