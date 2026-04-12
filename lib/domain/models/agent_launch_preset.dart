/// Supported coding-agent CLIs for host-scoped launch presets.
enum AgentLaunchTool {
  /// Anthropic Claude Code.
  claudeCode,

  /// GitHub Copilot CLI.
  copilotCli,

  /// Aider.
  aider,

  /// OpenAI Codex CLI.
  codex,

  /// OpenCode CLI.
  openCode,

  /// Google Gemini CLI.
  geminiCli,
}

/// Presentation helpers for [AgentLaunchTool].
extension AgentLaunchToolPresentation on AgentLaunchTool {
  /// Human-readable label for this tool.
  String get label => switch (this) {
    AgentLaunchTool.claudeCode => 'Claude Code',
    AgentLaunchTool.copilotCli => 'Copilot CLI',
    AgentLaunchTool.aider => 'Aider',
    AgentLaunchTool.codex => 'Codex',
    AgentLaunchTool.openCode => 'OpenCode',
    AgentLaunchTool.geminiCli => 'Gemini CLI',
  };

  /// Shell command used to launch this tool.
  String get commandName => switch (this) {
    AgentLaunchTool.claudeCode => 'claude',
    AgentLaunchTool.copilotCli => 'copilot',
    AgentLaunchTool.aider => 'aider',
    AgentLaunchTool.codex => 'codex',
    AgentLaunchTool.openCode => 'opencode',
    AgentLaunchTool.geminiCli => 'gemini',
  };

  /// Whether this tool supports session resume.
  bool get supportsResume => switch (this) {
    AgentLaunchTool.claudeCode => true,
    AgentLaunchTool.copilotCli => true,
    AgentLaunchTool.codex => true,
    AgentLaunchTool.openCode => true,
    AgentLaunchTool.geminiCli => true,
    AgentLaunchTool.aider => true,
  };
}

/// Host-scoped preset for launching a coding agent after connect.
class AgentLaunchPreset {
  /// Creates a new [AgentLaunchPreset].
  const AgentLaunchPreset({
    required this.tool,
    this.workingDirectory,
    this.tmuxSessionName,
    this.additionalArguments,
  });

  /// Decodes an [AgentLaunchPreset] from JSON.
  factory AgentLaunchPreset.fromJson(Map<String, dynamic> json) =>
      AgentLaunchPreset(
        tool: AgentLaunchTool.values.firstWhere(
          (value) => value.name == json['tool'],
          orElse: () => AgentLaunchTool.claudeCode,
        ),
        workingDirectory: _readTrimmedString(json['workingDirectory']),
        tmuxSessionName: _readTrimmedString(json['tmuxSessionName']),
        additionalArguments: _readTrimmedString(json['additionalArguments']),
      );

  /// Selected coding-agent CLI.
  final AgentLaunchTool tool;

  /// Optional directory to `cd` into before launching the agent.
  final String? workingDirectory;

  /// Optional tmux session to create or attach before launching the agent.
  final String? tmuxSessionName;

  /// Optional extra arguments passed to the CLI.
  final String? additionalArguments;

  /// Whether this preset uses a tmux session.
  bool get usesTmuxSession =>
      tmuxSessionName != null && tmuxSessionName!.trim().isNotEmpty;

  /// Whether this preset changes to a working directory first.
  bool get hasWorkingDirectory =>
      workingDirectory != null && workingDirectory!.trim().isNotEmpty;

  /// Encodes this preset as JSON.
  Map<String, dynamic> toJson() => {
    'tool': tool.name,
    if (workingDirectory case final value? when value.trim().isNotEmpty)
      'workingDirectory': value.trim(),
    if (tmuxSessionName case final value? when value.trim().isNotEmpty)
      'tmuxSessionName': value.trim(),
    if (additionalArguments case final value? when value.trim().isNotEmpty)
      'additionalArguments': value.trim(),
  };

  /// Returns a copy of this preset with selected fields replaced.
  AgentLaunchPreset copyWith({
    AgentLaunchTool? tool,
    String? workingDirectory,
    String? tmuxSessionName,
    String? additionalArguments,
  }) => AgentLaunchPreset(
    tool: tool ?? this.tool,
    workingDirectory: workingDirectory ?? this.workingDirectory,
    tmuxSessionName: tmuxSessionName ?? this.tmuxSessionName,
    additionalArguments: additionalArguments ?? this.additionalArguments,
  );
}

/// Builds the shell command for a saved agent launch preset.
String buildAgentLaunchCommand(AgentLaunchPreset preset) {
  final baseCommand = [
    preset.tool.commandName,
    if (preset.additionalArguments case final value?
        when value.trim().isNotEmpty)
      value.trim(),
  ].join(' ');

  final tmuxSessionName = preset.tmuxSessionName?.trim();
  final workingDirectory = preset.workingDirectory?.trim();
  if (tmuxSessionName != null && tmuxSessionName.isNotEmpty) {
    final commandParts = <String>[
      'tmux new-session -A -s ${_quoteShellArgument(tmuxSessionName)}',
      if (workingDirectory != null && workingDirectory.isNotEmpty)
        '-c ${_quoteShellPath(workingDirectory)}',
      _quoteShellArgument(baseCommand),
    ];
    return commandParts.join(' ');
  }

  if (workingDirectory != null && workingDirectory.isNotEmpty) {
    return 'cd ${_quoteShellPath(workingDirectory)} && $baseCommand';
  }

  return baseCommand;
}

String _quoteShellPath(String value) {
  if (value == '~') {
    return r'$HOME';
  }
  if (value.startsWith('~/')) {
    final relativePath = value.substring(2);
    if (relativePath.isEmpty) {
      return r'$HOME';
    }
    return '"\$HOME/${_escapeForDoubleQuotedShellContent(relativePath)}"';
  }
  return _quoteShellArgument(value);
}

String _quoteShellArgument(String value) =>
    '\'${value.replaceAll('\'', '\'"\'"\'')}\'';

String _escapeForDoubleQuotedShellContent(String value) => value
    .replaceAll(RegExp(r'\\'), r'\\')
    .replaceAll('"', r'\"')
    .replaceAll(r'$', r'\$')
    .replaceAll('`', r'\`');

String? _readTrimmedString(Object? value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
