import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import 'settings_service.dart';

/// Persists host-scoped coding-agent launch presets in app settings.
class AgentLaunchPresetService {
  /// Creates a new [AgentLaunchPresetService].
  AgentLaunchPresetService(this._settings);

  final SettingsService _settings;

  /// Loads the saved preset for [hostId], if one exists.
  Future<AgentLaunchPreset?> getPresetForHost(int hostId) async {
    final presets = await _readPresetMap();
    final value = presets[hostId.toString()];
    if (value is! Map<String, dynamic>) {
      return null;
    }
    return AgentLaunchPreset.fromJson(value);
  }

  /// Saves [preset] for [hostId].
  Future<void> setPresetForHost(int hostId, AgentLaunchPreset preset) async {
    final presets = await _readPresetMap();
    presets[hostId.toString()] = preset.toJson();
    await _settings.setJson(SettingKeys.agentLaunchPresets, presets);
  }

  /// Removes any saved preset for [hostId].
  Future<void> deletePresetForHost(int hostId) async {
    final presets = await _readPresetMap();
    presets.remove(hostId.toString());
    if (presets.isEmpty) {
      await _settings.delete(SettingKeys.agentLaunchPresets);
      return;
    }
    await _settings.setJson(SettingKeys.agentLaunchPresets, presets);
  }

  Future<Map<String, dynamic>> _readPresetMap() async =>
      await _settings.getJson(SettingKeys.agentLaunchPresets) ?? {};
}

/// Provider for [AgentLaunchPresetService].
final agentLaunchPresetServiceProvider = Provider<AgentLaunchPresetService>(
  (ref) => AgentLaunchPresetService(ref.watch(settingsServiceProvider)),
);
