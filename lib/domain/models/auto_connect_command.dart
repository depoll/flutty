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

final _disallowedCommandControlCharacters = RegExp(
  r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',
);
final _multilinePattern = RegExp(r'[\r\n]');
final _shellChainingPattern = RegExp(r'&&|\|\||[;|]');
final _shellRedirectionPattern = RegExp('>>?|<');

/// Reasons a terminal command should be reviewed before it is inserted or run.
enum TerminalCommandReviewReason {
  /// The command came from imported auto-connect configuration.
  importedAutoConnect,

  /// The command spans multiple lines.
  multiline,

  /// The command contains control characters that are not normally visible.
  controlCharacters,

  /// The command chains multiple shell operations together.
  shellChaining,

  /// The command redirects input or output.
  redirection,

  /// The command uses shell command substitution.
  commandSubstitution,

  /// The command was rendered from snippet variables.
  variableSubstitution,
}

/// Review metadata for a terminal command before insertion or execution.
class TerminalCommandReview {
  /// Creates a [TerminalCommandReview].
  const TerminalCommandReview({
    required this.command,
    required this.reasons,
    this.bracketedPasteModeEnabled = false,
  });

  /// The fully rendered command text.
  final String command;

  /// Reasons why the command should be reviewed.
  final List<TerminalCommandReviewReason> reasons;

  /// Whether bracketed paste mode is active for the current terminal session.
  final bool bracketedPasteModeEnabled;

  /// Whether this command should be confirmed with the user before use.
  bool get requiresReview => reasons.isNotEmpty;

  /// Whether the command contains multiple lines.
  bool get isMultiline =>
      reasons.contains(TerminalCommandReviewReason.multiline);
}

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

/// Ensures a shell command ends with an Enter key sequence before sending it.
String formatAutoConnectCommandForShell(String command) {
  if (command.endsWith('\r') || command.endsWith('\n')) {
    return command;
  }
  return '$command\r';
}

/// Rejects imported auto-connect text with hidden control characters.
void validateImportedAutoConnectCommandText(String command) {
  if (_disallowedCommandControlCharacters.hasMatch(command)) {
    throw const FormatException(
      'Imported auto-connect command contains unsupported control characters',
    );
  }
}

/// Normalizes an imported auto-connect command before it is stored locally.
String? normalizeImportedAutoConnectCommand(String? command) {
  if (!_hasVisibleContent(command)) {
    return null;
  }

  final normalized = command!.trim();
  validateImportedAutoConnectCommandText(normalized);
  return normalized;
}

/// Whether an imported host auto-connect command needs first-run review.
bool importedAutoConnectRequiresReview({
  required String? command,
  required int? snippetId,
}) =>
    resolveAutoConnectCommandMode(command: command, snippetId: snippetId) !=
    AutoConnectCommandMode.none;

/// Assesses a clipboard paste for multiline or suspicious shell content.
TerminalCommandReview assessClipboardPasteCommand(
  String command, {
  required bool bracketedPasteModeEnabled,
}) => TerminalCommandReview(
  command: command,
  reasons: _collectSuspiciousCommandReasons(command),
  bracketedPasteModeEnabled: bracketedPasteModeEnabled,
);

/// Assesses a rendered snippet command before terminal insertion.
TerminalCommandReview assessSnippetCommandInsertion(
  String command, {
  required bool hadVariableSubstitution,
}) {
  final reasons = <TerminalCommandReviewReason>[];
  if (hadVariableSubstitution) {
    reasons
      ..add(TerminalCommandReviewReason.variableSubstitution)
      ..addAll(_collectSuspiciousCommandReasons(command));
  }
  return TerminalCommandReview(command: command, reasons: reasons);
}

/// Assesses an auto-connect command before it is executed automatically.
TerminalCommandReview assessAutoConnectCommandExecution(
  String command, {
  required bool importedNeedsReview,
}) {
  final reasons = <TerminalCommandReviewReason>[];
  if (importedNeedsReview) {
    reasons
      ..add(TerminalCommandReviewReason.importedAutoConnect)
      ..addAll(_collectSuspiciousCommandReasons(command));
  }
  return TerminalCommandReview(command: command, reasons: reasons);
}

/// Human-readable descriptions for [TerminalCommandReview.reasons].
List<String> describeTerminalCommandReview(TerminalCommandReview review) =>
    review.reasons.map(_describeReviewReason).toList(growable: false);

List<TerminalCommandReviewReason> _collectSuspiciousCommandReasons(
  String command,
) {
  final reasons = <TerminalCommandReviewReason>[];
  if (_multilinePattern.hasMatch(command)) {
    reasons.add(TerminalCommandReviewReason.multiline);
  }
  if (_disallowedCommandControlCharacters.hasMatch(command)) {
    reasons.add(TerminalCommandReviewReason.controlCharacters);
  }
  if (_shellChainingPattern.hasMatch(command)) {
    reasons.add(TerminalCommandReviewReason.shellChaining);
  }
  if (_shellRedirectionPattern.hasMatch(command)) {
    reasons.add(TerminalCommandReviewReason.redirection);
  }
  if (command.contains('`') || command.contains(r'$(')) {
    reasons.add(TerminalCommandReviewReason.commandSubstitution);
  }
  return reasons;
}

String _describeReviewReason(TerminalCommandReviewReason reason) =>
    switch (reason) {
      TerminalCommandReviewReason.importedAutoConnect =>
        'Imported auto-connect commands need review before they can run.',
      TerminalCommandReviewReason.multiline =>
        'This command spans multiple lines.',
      TerminalCommandReviewReason.controlCharacters =>
        'This command contains hidden control characters.',
      TerminalCommandReviewReason.shellChaining =>
        'This command chains multiple shell operations.',
      TerminalCommandReviewReason.redirection =>
        'This command redirects input or output.',
      TerminalCommandReviewReason.commandSubstitution =>
        'This command uses shell command substitution.',
      TerminalCommandReviewReason.variableSubstitution =>
        'Snippet variables were substituted into the final command.',
    };

bool _hasVisibleContent(String? value) =>
    value != null && value.trim().isNotEmpty;
