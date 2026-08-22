/// Host-scoped default for launching ACP-capable coding agents.
enum AgentWindowModePreference {
  /// Ask whether to use the terminal or native chat for every launch.
  askEveryTime,

  /// Open ACP-capable agents in native chat by default.
  preferNative,

  /// Open ACP-capable agents in a terminal window by default.
  preferTerminal,
}

/// Persistence and presentation helpers for [AgentWindowModePreference].
extension AgentWindowModePreferencePresentation on AgentWindowModePreference {
  /// Stable settings value.
  String get storageValue => switch (this) {
    AgentWindowModePreference.askEveryTime => 'ask',
    AgentWindowModePreference.preferNative => 'native',
    AgentWindowModePreference.preferTerminal => 'terminal',
  };

  /// Human-readable label used in host settings.
  String get label => switch (this) {
    AgentWindowModePreference.askEveryTime => 'Ask every time',
    AgentWindowModePreference.preferNative => 'Prefer native chat',
    AgentWindowModePreference.preferTerminal => 'Prefer terminal',
  };

  /// Parses a stored preference, falling back safely for old or unknown data.
  static AgentWindowModePreference fromStorageValue(Object? value) =>
      switch (value) {
        'native' => AgentWindowModePreference.preferNative,
        'terminal' => AgentWindowModePreference.preferTerminal,
        _ => AgentWindowModePreference.askEveryTime,
      };
}

/// Host-scoped defaults for coding CLI launches.
class HostCliLaunchPreferences {
  /// Creates a new [HostCliLaunchPreferences].
  const HostCliLaunchPreferences({
    this.startInYoloMode = false,
    this.agentWindowMode = AgentWindowModePreference.askEveryTime,
  });

  /// Decodes [HostCliLaunchPreferences] from JSON.
  factory HostCliLaunchPreferences.fromJson(Map<String, dynamic> json) =>
      HostCliLaunchPreferences(
        startInYoloMode: json['startInYoloMode'] == true,
        agentWindowMode: AgentWindowModePreferencePresentation.fromStorageValue(
          json['agentWindowMode'],
        ),
      );

  /// Whether supported coding CLIs should launch in YOLO mode for this host.
  final bool startInYoloMode;

  /// Default surface for ACP-capable coding-agent launches on this host.
  final AgentWindowModePreference agentWindowMode;

  /// Whether this preferences record has no saved overrides.
  bool get isEmpty =>
      !startInYoloMode &&
      agentWindowMode == AgentWindowModePreference.askEveryTime;

  /// Encodes this preferences record as JSON.
  Map<String, dynamic> toJson() => {
    if (startInYoloMode) 'startInYoloMode': true,
    if (agentWindowMode != AgentWindowModePreference.askEveryTime)
      'agentWindowMode': agentWindowMode.storageValue,
  };

  /// Returns a copy of this record with selected fields replaced.
  HostCliLaunchPreferences copyWith({
    bool? startInYoloMode,
    AgentWindowModePreference? agentWindowMode,
  }) => HostCliLaunchPreferences(
    startInYoloMode: startInYoloMode ?? this.startInYoloMode,
    agentWindowMode: agentWindowMode ?? this.agentWindowMode,
  );
}
