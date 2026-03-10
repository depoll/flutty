/// Supported host auto-connect command sources.
enum AutoConnectCommandMode {
  /// Do not run a command automatically.
  none,

  /// Run the host's saved custom command.
  custom,

  /// Run the command from a selected snippet.
  snippet,
}

/// Suggested tmux command for automatic startup after connecting.
const defaultAutoConnectCommandSuggestion = 'tmux new -As MonkeySSH';

/// Resolves the effective auto-connect mode from persisted host fields.
AutoConnectCommandMode resolveAutoConnectCommandMode({
  required String? command,
  required int? snippetId,
}) {
  if (snippetId != null) {
    return AutoConnectCommandMode.snippet;
  }
  if (_hasVisibleContent(command)) {
    return AutoConnectCommandMode.custom;
  }
  return AutoConnectCommandMode.none;
}

/// Resolves the command text that should be sent to the shell.
String? resolveAutoConnectCommandText({
  required AutoConnectCommandMode mode,
  String? storedCommand,
  String? snippetCommand,
}) => switch (mode) {
  AutoConnectCommandMode.none => null,
  AutoConnectCommandMode.custom =>
    _hasVisibleContent(storedCommand) ? storedCommand : null,
  AutoConnectCommandMode.snippet =>
    _hasVisibleContent(snippetCommand)
        ? snippetCommand
        : _hasVisibleContent(storedCommand)
        ? storedCommand
        : null,
};

/// Ensures a shell command ends with a newline before sending it.
String formatAutoConnectCommandForShell(String command) =>
    command.endsWith('\n') ? command : '$command\n';

bool _hasVisibleContent(String? value) =>
    value != null && value.trim().isNotEmpty;
