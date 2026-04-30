import 'tmux_state.dart';

/// Supported coding-agent CLIs for host-scoped launch presets.
enum AgentLaunchTool {
  /// Anthropic Claude Code.
  claudeCode,

  /// GitHub Copilot CLI.
  copilotCli,

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
    AgentLaunchTool.codex => 'Codex',
    AgentLaunchTool.openCode => 'OpenCode',
    AgentLaunchTool.geminiCli => 'Gemini CLI',
  };

  /// Shell command used to launch this tool.
  String get commandName => switch (this) {
    AgentLaunchTool.claudeCode => 'claude',
    AgentLaunchTool.copilotCli => 'copilot',
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
  };

  /// Matching discovered-session provider name, if this tool supports recent
  /// session discovery.
  String? get discoveredSessionToolName => switch (this) {
    AgentLaunchTool.claudeCode => 'Claude Code',
    AgentLaunchTool.copilotCli => 'Copilot CLI',
    AgentLaunchTool.codex => 'Codex',
    AgentLaunchTool.openCode => 'OpenCode',
    AgentLaunchTool.geminiCli => 'Gemini CLI',
  };

  /// Whether this tool supports launching directly into YOLO mode.
  bool get supportsYoloMode =>
      yoloArguments.isNotEmpty || yoloEnvironment.isNotEmpty;

  /// Command-line arguments that enable YOLO mode for this tool.
  List<String> get yoloArguments => switch (this) {
    AgentLaunchTool.claudeCode => const ['--dangerously-skip-permissions'],
    AgentLaunchTool.copilotCli => const ['--yolo'],
    AgentLaunchTool.codex => const ['--yolo'],
    AgentLaunchTool.openCode => const [],
    AgentLaunchTool.geminiCli => const ['--yolo'],
  };

  /// Environment variables that enable YOLO mode for this tool.
  Map<String, String> get yoloEnvironment => switch (this) {
    AgentLaunchTool.openCode => const {'OPENCODE_PERMISSION': '{"*":"allow"}'},
    _ => const <String, String>{},
  };
}

/// Resolves a supported agent CLI from a command or binary name.
///
/// The input may be a bare executable (`claude`), a full path
/// (`/opt/homebrew/bin/codex`), or a command token with trailing arguments.
AgentLaunchTool? agentLaunchToolForCommandName(String? commandName) {
  final normalized = _normalizeAgentCommandName(commandName);
  if (normalized == null) {
    return null;
  }

  for (final tool in AgentLaunchTool.values) {
    if (tool.commandName == normalized) {
      return tool;
    }
  }
  return null;
}

/// Resolves a supported agent CLI from a full shell command.
///
/// This accepts commands with environment assignments, paths, and arguments
/// because tmux can expose wrapper commands rather than a bare executable.
AgentLaunchTool? agentLaunchToolForCommandText(String? command) {
  var normalized = command?.trim() ?? '';
  if (normalized.isEmpty) {
    return null;
  }

  while (true) {
    final cdMatch = _leadingCdCommandPattern.firstMatch(normalized);
    if (cdMatch == null) break;
    normalized = normalized.substring(cdMatch.end).trimLeft();
  }

  while (true) {
    final assignmentMatch = _leadingEnvironmentAssignmentPattern.firstMatch(
      normalized,
    );
    if (assignmentMatch == null) break;
    normalized = normalized.substring(assignmentMatch.end).trimLeft();
  }

  return agentLaunchToolForCommandName(_readLeadingShellToken(normalized));
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
      orElse: () => AgentLaunchTool.claudeCode,
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

String? _normalizeAgentCommandName(String? commandName) {
  final trimmed = commandName?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }

  final token = trimmed.split(RegExp(r'\s+')).first;
  final basename = token.split(RegExp(r'[\\/]')).last.toLowerCase();
  if (basename.isEmpty) {
    return null;
  }
  return basename.replaceFirst(RegExp(r'\.exe$'), '');
}

String? _readLeadingShellToken(String value) {
  final trimmed = value.trimLeft();
  if (trimmed.isEmpty) return null;
  final quote = trimmed.codeUnitAt(0);
  if (quote == 0x22 || quote == 0x27) {
    final end = trimmed.indexOf(String.fromCharCode(quote), 1);
    if (end > 1) {
      return trimmed.substring(1, end);
    }
  }
  return trimmed.split(RegExp(r'\s+')).first;
}

final _unquotedTmuxFlagTokenPattern = RegExp(r'^[A-Za-z0-9_./~:=,+-]+$');
final _leadingCdCommandPattern = RegExp(
  r'''^cd\s+(?:"[^"]*"|'[^']*'|\S+)\s*&&\s*''',
);
final _leadingEnvironmentAssignmentPattern = RegExp(
  r'''^[A-Za-z_][A-Za-z0-9_]*=(?:"(?:[^"\\]|\\.)*"|'[^']*'|\S+)\s+''',
);
final _codexApprovalModeEqualsPattern = RegExp(
  r'''(?<!\S)--approval-mode=(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexApprovalModeSeparatedPattern = RegExp(
  r'''(?<!\S)--approval-mode\s+(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexAskForApprovalEqualsPattern = RegExp(
  r'''(?<!\S)--ask-for-approval=(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexAskForApprovalSeparatedPattern = RegExp(
  r'''(?<!\S)--ask-for-approval\s+(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexShortApprovalPattern = RegExp(
  r'''(?<!\S)-a\s+(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexSandboxEqualsPattern = RegExp(
  r'''(?<!\S)--sandbox=(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexSandboxSeparatedPattern = RegExp(
  r'''(?<!\S)--sandbox\s+(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexShortSandboxPattern = RegExp(
  r'''(?<!\S)-s\s+(?:"[^"]*"|'[^']*'|\S+)''',
);
final _codexFullAutoPattern = RegExp(r'(?<!\S)--full-auto(?=\s|$)');
final _codexYoloPattern = RegExp(r'(?<!\S)--yolo(?=\s|$)');
final _codexDangerousBypassPattern = RegExp(
  r'(?<!\S)--dangerously-bypass-approvals-and-sandbox(?=\s|$)',
);
final _claudeDangerouslySkipPermissionsPattern = RegExp(
  r'(?<!\S)--dangerously-skip-permissions(?=\s|$)',
);
final _claudePermissionModeEqualsPattern = RegExp(
  r'''(?<!\S)--permission-mode=(?:"[^"]*"|'[^']*'|\S+)''',
);
final _claudePermissionModeSeparatedPattern = RegExp(
  r'''(?<!\S)--permission-mode\s+(?:"[^"]*"|'[^']*'|\S+)''',
);
final _copilotAllowAllPattern = RegExp(r'(?<!\S)--allow-all(?=\s|$)');
final _copilotYoloPattern = RegExp(r'(?<!\S)--yolo(?=\s|$)');
final _copilotAllowAllToolsPattern = RegExp(
  r'(?<!\S)--allow-all-tools(?=\s|$)',
);
final _copilotAllowAllPathsPattern = RegExp(
  r'(?<!\S)--allow-all-paths(?=\s|$)',
);
final _copilotAllowAllUrlsPattern = RegExp(r'(?<!\S)--allow-all-urls(?=\s|$)');
final _geminiYoloPattern = RegExp(r'(?<!\S)(?:--yolo|-y)(?=\s|$)');
final _openCodeDangerouslySkipPermissionsPattern = RegExp(
  r'(?<!\S)--dangerously-skip-permissions(?=\s|$)',
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
      tmuxEnableFocusEventsCommand,
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
  final commandParts = <String>[
    ..._buildAgentToolEnvironmentAssignments(
      tool,
      startInYoloMode: startInYoloMode,
    ),
    tool.commandName,
  ];
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
  final trimmedAdditionalArguments = additionalArguments?.trim();
  if (!startInYoloMode) {
    return trimmedAdditionalArguments;
  }

  final sanitizedAdditionalArguments = switch (tool) {
    AgentLaunchTool.claudeCode =>
      _stripArgumentPatterns(trimmedAdditionalArguments, [
        _claudeDangerouslySkipPermissionsPattern,
        _claudePermissionModeEqualsPattern,
        _claudePermissionModeSeparatedPattern,
      ]),
    AgentLaunchTool.copilotCli =>
      _stripArgumentPatterns(trimmedAdditionalArguments, [
        _copilotAllowAllPattern,
        _copilotYoloPattern,
        _copilotAllowAllToolsPattern,
        _copilotAllowAllPathsPattern,
        _copilotAllowAllUrlsPattern,
      ]),
    AgentLaunchTool.codex => _stripCodexYoloConflicts(
      trimmedAdditionalArguments,
    ),
    AgentLaunchTool.openCode => _stripArgumentPatterns(
      trimmedAdditionalArguments,
      [_openCodeDangerouslySkipPermissionsPattern],
    ),
    AgentLaunchTool.geminiCli => _stripArgumentPatterns(
      trimmedAdditionalArguments,
      [_geminiYoloPattern],
    ),
  };

  final yoloArguments = tool.yoloArguments;
  if (yoloArguments.isEmpty) {
    return sanitizedAdditionalArguments;
  }

  if (sanitizedAdditionalArguments == null ||
      sanitizedAdditionalArguments.isEmpty) {
    return yoloArguments.join(' ');
  }

  return '${yoloArguments.join(' ')} $sanitizedAdditionalArguments';
}

List<String> _buildAgentToolEnvironmentAssignments(
  AgentLaunchTool tool, {
  required bool startInYoloMode,
}) => !startInYoloMode
    ? const []
    : tool.yoloEnvironment.entries
          .map(
            (entry) => _quoteShellEnvironmentAssignment(entry.key, entry.value),
          )
          .toList(growable: false);

String? _stripCodexYoloConflicts(String? additionalArguments) =>
    _stripArgumentPatterns(additionalArguments, [
      _codexApprovalModeEqualsPattern,
      _codexApprovalModeSeparatedPattern,
      _codexAskForApprovalEqualsPattern,
      _codexAskForApprovalSeparatedPattern,
      _codexShortApprovalPattern,
      _codexSandboxEqualsPattern,
      _codexSandboxSeparatedPattern,
      _codexShortSandboxPattern,
      _codexFullAutoPattern,
      _codexYoloPattern,
      _codexDangerousBypassPattern,
    ]);

String? _stripArgumentPatterns(
  String? additionalArguments,
  List<RegExp> patterns,
) {
  final trimmedAdditionalArguments = additionalArguments?.trim();
  if (trimmedAdditionalArguments == null ||
      trimmedAdditionalArguments.isEmpty) {
    return null;
  }

  final normalizedArguments = patterns
      .fold<String>(
        trimmedAdditionalArguments,
        (value, pattern) => value.replaceAll(pattern, ' '),
      )
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

String _quoteShellEnvironmentAssignment(String key, String value) =>
    '$key="${_escapeForDoubleQuotedShellContent(value)}"';

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
