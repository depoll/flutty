import 'tmux_state.dart';

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
    AgentLaunchTool.aider => true,
    AgentLaunchTool.codex => true,
    AgentLaunchTool.openCode => true,
    AgentLaunchTool.geminiCli => true,
  };

  /// Matching discovered-session provider name, if this tool supports recent
  /// session discovery.
  String? get discoveredSessionToolName => switch (this) {
    AgentLaunchTool.claudeCode => 'Claude Code',
    AgentLaunchTool.copilotCli => 'Copilot CLI',
    AgentLaunchTool.aider => null,
    AgentLaunchTool.codex => 'Codex',
    AgentLaunchTool.openCode => 'OpenCode',
    AgentLaunchTool.geminiCli => 'Gemini CLI',
  };

  /// Whether this tool supports launching directly into YOLO mode.
  bool get supportsYoloMode => yoloArgument != null;

  /// Command-line argument that enables YOLO mode for this tool, if available.
  String? get yoloArgument => switch (this) {
    AgentLaunchTool.claudeCode => '--dangerously-skip-permissions',
    AgentLaunchTool.copilotCli => null,
    AgentLaunchTool.aider => '--yes-always',
    AgentLaunchTool.codex => '--approval-mode never',
    AgentLaunchTool.openCode => null,
    AgentLaunchTool.geminiCli => '--yolo',
  };
}

/// Host-scoped preset for launching a coding agent after connect.
class AgentLaunchPreset {
  /// Creates a new [AgentLaunchPreset].
  const AgentLaunchPreset({
    required this.tool,
    this.workingDirectory,
    this.tmuxSessionName,
    this.tmuxExtraFlags,
    this.tmuxDisableStatusBar = false,
    this.additionalArguments,
  });

  /// Decodes an [AgentLaunchPreset] from JSON.
  factory AgentLaunchPreset.fromJson(Map<String, dynamic> json) {
    final rawTool = _readTrimmedString(json['tool']);
    final tool = AgentLaunchTool.values.firstWhere(
      (value) => value.name == rawTool,
      orElse: () => switch (rawTool) {
        'aider' => AgentLaunchTool.aider,
        _ => AgentLaunchTool.claudeCode,
      },
    );
    return AgentLaunchPreset(
      tool: tool,
      workingDirectory: _readTrimmedString(json['workingDirectory']),
      tmuxSessionName: _readTrimmedString(json['tmuxSessionName']),
      tmuxExtraFlags: _readTrimmedString(json['tmuxExtraFlags']),
      tmuxDisableStatusBar: json['tmuxDisableStatusBar'] == true,
      additionalArguments: _readTrimmedString(json['additionalArguments']),
    );
  }

  /// Selected coding-agent CLI.
  final AgentLaunchTool tool;

  /// Optional directory to `cd` into before launching the agent.
  final String? workingDirectory;

  /// Optional tmux session to create or attach before launching the agent.
  final String? tmuxSessionName;

  /// Optional `tmux new-session` flags passed before the agent command.
  final String? tmuxExtraFlags;

  /// Whether tmux's built-in status bar should be disabled for this session.
  final bool tmuxDisableStatusBar;

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
    if (tmuxExtraFlags case final value? when value.trim().isNotEmpty)
      'tmuxExtraFlags': value.trim(),
    if (tmuxDisableStatusBar) 'tmuxDisableStatusBar': true,
    if (additionalArguments case final value? when value.trim().isNotEmpty)
      'additionalArguments': value.trim(),
  };

  /// Returns a copy of this preset with selected fields replaced.
  AgentLaunchPreset copyWith({
    AgentLaunchTool? tool,
    String? workingDirectory,
    String? tmuxSessionName,
    String? tmuxExtraFlags,
    bool? tmuxDisableStatusBar,
    String? additionalArguments,
  }) => AgentLaunchPreset(
    tool: tool ?? this.tool,
    workingDirectory: workingDirectory ?? this.workingDirectory,
    tmuxSessionName: tmuxSessionName ?? this.tmuxSessionName,
    tmuxExtraFlags: tmuxExtraFlags ?? this.tmuxExtraFlags,
    tmuxDisableStatusBar: tmuxDisableStatusBar ?? this.tmuxDisableStatusBar,
    additionalArguments: additionalArguments ?? this.additionalArguments,
  );
}

enum _ShellQuoteMode { none, single, double }

const _backslashCodeUnit = 0x5C;

final _unquotedTmuxFlagTokenPattern = RegExp(r'^[A-Za-z0-9_./~:=,+-]+$');
final _codexApprovalModeEqualsPattern = RegExp(
  r'''(?<!\S)--approval-mode=(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexApprovalModeSeparatedPattern = RegExp(
  r'''(?<!\S)--approval-mode\s+(?:"[^"]*"|'[^']*'|\S+)''',
);

/// Builds the shell command for a saved agent launch preset.
String buildAgentLaunchCommand(
  AgentLaunchPreset preset, {
  bool startInYoloMode = false,
}) {
  final baseCommand = buildAgentToolCommand(
    preset.tool,
    additionalArguments: preset.additionalArguments,
    startInYoloMode: startInYoloMode,
  );

  final tmuxSessionName = preset.tmuxSessionName?.trim();
  final workingDirectory = preset.workingDirectory?.trim();
  if (tmuxSessionName != null && tmuxSessionName.isNotEmpty) {
    final tmuxExtraFlags = _tokenizeTmuxNewSessionFlags(preset.tmuxExtraFlags);
    final commandParts = <String>[
      'tmux new-session -A -s ${_quoteShellArgument(tmuxSessionName)}',
      if (workingDirectory != null && workingDirectory.isNotEmpty)
        '-c ${_quoteShellPath(workingDirectory)}',
      ...tmuxExtraFlags.map(_quoteTmuxFlagToken),
      _quoteShellArgument(baseCommand),
      if (preset.tmuxDisableStatusBar) tmuxDisableStatusBarCommand,
    ];
    return commandParts.join(' ');
  }

  if (workingDirectory != null && workingDirectory.isNotEmpty) {
    return 'cd ${_quoteShellPath(workingDirectory)} && $baseCommand';
  }

  return baseCommand;
}

/// Builds the base shell command for launching [tool].
String buildAgentToolCommand(
  AgentLaunchTool tool, {
  String? additionalArguments,
  bool startInYoloMode = false,
}) {
  final commandParts = <String>[tool.commandName];
  final normalizedArguments = _normalizeAgentToolArguments(
    tool: tool,
    additionalArguments: additionalArguments,
    startInYoloMode: startInYoloMode,
  );
  if (normalizedArguments != null && normalizedArguments.isNotEmpty) {
    commandParts.add(normalizedArguments);
  }
  return commandParts.join(' ');
}

String? _normalizeAgentToolArguments({
  required AgentLaunchTool tool,
  required String? additionalArguments,
  required bool startInYoloMode,
}) {
  final yoloArgument = tool.yoloArgument;
  final trimmedAdditionalArguments = additionalArguments?.trim();
  if (!startInYoloMode || yoloArgument == null) {
    return trimmedAdditionalArguments;
  }

  final sanitizedAdditionalArguments = switch (tool) {
    AgentLaunchTool.codex => _stripCodexApprovalModeArguments(
      trimmedAdditionalArguments,
    ),
    _ => trimmedAdditionalArguments,
  };

  if (sanitizedAdditionalArguments == null ||
      sanitizedAdditionalArguments.isEmpty) {
    return yoloArgument;
  }

  if (sanitizedAdditionalArguments.contains(yoloArgument)) {
    return sanitizedAdditionalArguments;
  }

  return '$yoloArgument $sanitizedAdditionalArguments';
}

String? _stripCodexApprovalModeArguments(String? additionalArguments) {
  final trimmedAdditionalArguments = additionalArguments?.trim();
  if (trimmedAdditionalArguments == null ||
      trimmedAdditionalArguments.isEmpty) {
    return null;
  }

  final normalizedArguments = trimmedAdditionalArguments
      .replaceAll(_codexApprovalModeEqualsPattern, ' ')
      .replaceAll(_codexApprovalModeSeparatedPattern, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return normalizedArguments.isEmpty ? null : normalizedArguments;
}

List<String> _tokenizeTmuxNewSessionFlags(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return const [];
  }
  if (normalized.contains('\n') || normalized.contains('\r')) {
    throw const FormatException(
      'tmux new-session flags must stay on one line.',
    );
  }

  final tokens = <String>[];
  var currentToken = StringBuffer();
  var tokenStarted = false;
  var quoteMode = _ShellQuoteMode.none;

  void commitToken() {
    if (!tokenStarted) {
      return;
    }
    final token = currentToken.toString();
    if (_isTmuxCommandSeparatorToken(token)) {
      throw const FormatException(
        r'tmux new-session flags cannot include tmux command separators like \;.',
      );
    }
    tokens.add(token);
    currentToken = StringBuffer();
    tokenStarted = false;
  }

  for (var index = 0; index < normalized.length; index++) {
    final character = normalized[index];

    if (quoteMode == _ShellQuoteMode.single) {
      if (character == "'") {
        quoteMode = _ShellQuoteMode.none;
      } else {
        tokenStarted = true;
        currentToken.write(character);
      }
      continue;
    }

    if (quoteMode == _ShellQuoteMode.double) {
      if (character == '"') {
        quoteMode = _ShellQuoteMode.none;
        continue;
      }
      if (character.codeUnitAt(0) == _backslashCodeUnit) {
        if (index + 1 >= normalized.length) {
          throw const FormatException(
            'tmux new-session flags cannot end with an escape character.',
          );
        }
        final nextCharacter = normalized[index + 1];
        if (nextCharacter == '"' ||
            nextCharacter.codeUnitAt(0) == _backslashCodeUnit ||
            nextCharacter == r'$' ||
            nextCharacter == '`') {
          tokenStarted = true;
          currentToken.write(nextCharacter);
          index++;
          continue;
        }
      }
      tokenStarted = true;
      currentToken.write(character);
      continue;
    }

    if (character == ' ' || character == '\t') {
      commitToken();
      continue;
    }
    if (character == "'") {
      tokenStarted = true;
      quoteMode = _ShellQuoteMode.single;
      continue;
    }
    if (character == '"') {
      tokenStarted = true;
      quoteMode = _ShellQuoteMode.double;
      continue;
    }
    if (character.codeUnitAt(0) == _backslashCodeUnit) {
      if (index + 1 >= normalized.length) {
        throw const FormatException(
          'tmux new-session flags cannot end with an escape character.',
        );
      }
      tokenStarted = true;
      currentToken.write(normalized[index + 1]);
      index++;
      continue;
    }
    tokenStarted = true;
    currentToken.write(character);
  }

  if (quoteMode != _ShellQuoteMode.none) {
    throw const FormatException(
      'tmux new-session flags contain an unterminated quote.',
    );
  }

  commitToken();
  return tokens;
}

bool _isTmuxCommandSeparatorToken(String value) => value == ';';

String _quoteTmuxFlagToken(String value) =>
    _unquotedTmuxFlagTokenPattern.hasMatch(value)
    ? value
    : _quoteShellArgument(value);

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
