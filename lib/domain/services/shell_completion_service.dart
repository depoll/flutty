import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics_log_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

/// Type of completion being requested from the side-channel shell.
enum ShellCompletionMode {
  /// Complete the first command word.
  command,

  /// Complete only directories.
  directory,

  /// Complete files and directories.
  path,
}

/// Type of a single shell completion suggestion.
enum ShellCompletionSuggestionKind {
  /// A command name.
  command,

  /// A directory path.
  directory,

  /// A regular file path.
  file,
}

/// Completion context resolved from the visible terminal prompt.
class ShellCompletionInvocation {
  /// Creates a shell completion invocation.
  const ShellCompletionInvocation({
    required this.commandLine,
    required this.cursorOffset,
    required this.token,
    required this.tokenStart,
    required this.mode,
    required this.workingDirectory,
    this.commandName,
    this.maxSuggestions = 24,
  });

  /// Current command text without the prompt.
  final String commandLine;

  /// Cursor offset in [commandLine].
  final int cursorOffset;

  /// Current token before the cursor.
  final String token;

  /// Token start offset in [commandLine].
  final int tokenStart;

  /// Completion mode.
  final ShellCompletionMode mode;

  /// Parsed command name, when the cursor is in an argument.
  final String? commandName;

  /// Remote working directory to run completion lookups from.
  final String? workingDirectory;

  /// Maximum number of suggestions to keep.
  final int maxSuggestions;
}

/// A completion candidate that can be applied to the terminal line.
class ShellCompletionSuggestion {
  /// Creates a shell completion suggestion.
  const ShellCompletionSuggestion({
    required this.label,
    required this.replacement,
    required this.replacementStart,
    required this.replacementEnd,
    required this.kind,
    this.commitSuffix = '',
  });

  /// Text shown in the popup.
  final String label;

  /// Text to type after deleting [replacementStart] through [replacementEnd].
  final String replacement;

  /// Start offset in the command line to replace.
  final int replacementStart;

  /// End offset in the command line to replace.
  final int replacementEnd;

  /// Suggestion kind.
  final ShellCompletionSuggestionKind kind;

  /// Text to append after [replacement], such as a trailing command space.
  final String commitSuffix;
}

/// Resolves shell completions over a short-lived SSH exec side channel.
class ShellCompletionService {
  /// Creates a shell completion service.
  const ShellCompletionService({
    this.timeout = const Duration(milliseconds: 1500),
    this.maxOutputChars = 12000,
  });

  /// Maximum time to wait for a completion exec.
  final Duration timeout;

  /// Maximum stdout characters to buffer from the remote helper.
  final int maxOutputChars;

  /// Runs a completion query for [invocation].
  Future<List<ShellCompletionSuggestion>> complete(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    DiagnosticsLogService.instance.debug(
      'shell_completion',
      'request_start',
      fields: {
        'connectionId': session.connectionId,
        'mode': invocation.mode.name,
        'tokenLength': invocation.token.length,
        'hasWorkingDirectory':
            invocation.workingDirectory?.trim().isNotEmpty ?? false,
      },
    );

    final startedAt = DateTime.now();
    final output = await session.runQueuedExec(
      () => _runCompletionCommand(session, invocation),
      priority: SshExecPriority.low,
    );
    final suggestions = parseShellCompletionOutput(output, invocation);
    DiagnosticsLogService.instance.debug(
      'shell_completion',
      'request_complete',
      fields: {
        'connectionId': session.connectionId,
        'mode': invocation.mode.name,
        'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
        'suggestionCount': suggestions.length,
      },
    );
    return suggestions;
  }

  Future<String> _runCompletionCommand(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final command = buildShellCompletionRemoteCommand(invocation);
    final exec = await session.execute(command);
    try {
      final stdout = StringBuffer();
      final stdoutFuture = exec.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach((chunk) {
            if (stdout.length >= maxOutputChars) {
              return;
            }
            final remaining = maxOutputChars - stdout.length;
            stdout.write(
              chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
            );
          });
      final stderrFuture = exec.stderr.drain<void>();
      await Future.wait<void>([
        stdoutFuture,
        stderrFuture,
        exec.done,
      ]).timeout(timeout);
      return stdout.toString();
    } on TimeoutException {
      DiagnosticsLogService.instance.warning(
        'shell_completion',
        'request_timeout',
        fields: {
          'connectionId': session.connectionId,
          'mode': invocation.mode.name,
          'timeoutMs': timeout.inMilliseconds,
        },
      );
      rethrow;
    } finally {
      exec.close();
    }
  }
}

/// Provider for [ShellCompletionService].
final shellCompletionServiceProvider = Provider<ShellCompletionService>(
  (ref) => const ShellCompletionService(),
);

/// Builds a completion invocation from a rendered terminal line snapshot.
ShellCompletionInvocation? buildShellCompletionInvocation({
  required String terminalText,
  required int terminalCursorOffset,
  String? promptPrefix,
  String? workingDirectory,
  int maxSuggestions = 24,
}) {
  final commandSnapshot = resolveShellCompletionCommandLine(
    terminalText: terminalText,
    terminalCursorOffset: terminalCursorOffset,
    promptPrefix: promptPrefix,
  );
  if (commandSnapshot == null) {
    return null;
  }

  final commandLine = commandSnapshot.commandLine;
  final cursorOffset = commandSnapshot.cursorOffset;
  if (cursorOffset != commandLine.length || commandLine.length > 512) {
    return null;
  }
  if (commandLine.trim().isEmpty) {
    return null;
  }

  final tokenState = parseShellCompletionToken(commandLine, cursorOffset);
  if (tokenState == null || _containsShellQuote(tokenState.token)) {
    return null;
  }

  final commandName = tokenState.words.isEmpty
      ? null
      : normalizeShellCompletionToken(tokenState.words.first);
  final mode = tokenState.wordIndex == 0
      ? ShellCompletionMode.command
      : commandName == 'cd'
      ? ShellCompletionMode.directory
      : ShellCompletionMode.path;
  final normalizedToken = normalizeShellCompletionToken(tokenState.token);

  if (normalizedToken.isEmpty) {
    return null;
  }

  return ShellCompletionInvocation(
    commandLine: commandLine,
    cursorOffset: cursorOffset,
    token: normalizedToken,
    tokenStart: tokenState.tokenStart,
    mode: mode,
    commandName: commandName,
    workingDirectory: workingDirectory,
    maxSuggestions: maxSuggestions,
  );
}

/// Resolves command text from a terminal snapshot by removing the prompt.
@visibleForTesting
({String commandLine, int cursorOffset})? resolveShellCompletionCommandLine({
  required String terminalText,
  required int terminalCursorOffset,
  String? promptPrefix,
}) {
  if (terminalCursorOffset < 0 || terminalCursorOffset > terminalText.length) {
    return null;
  }

  final beforeCursor = terminalText.substring(0, terminalCursorOffset);
  final afterCursor = terminalText.substring(terminalCursorOffset);
  if (afterCursor.trimRight().isNotEmpty) {
    return null;
  }

  final promptEnd = _resolvePromptEnd(beforeCursor, promptPrefix);
  if (promptEnd > beforeCursor.length) {
    return null;
  }

  return (
    commandLine: beforeCursor.substring(promptEnd) + afterCursor,
    cursorOffset: beforeCursor.length - promptEnd,
  );
}

int _resolvePromptEnd(String beforeCursor, String? promptPrefix) {
  if (promptPrefix != null &&
      promptPrefix.isNotEmpty &&
      beforeCursor.startsWith(promptPrefix)) {
    return promptPrefix.length;
  }

  return _findLikelyPromptEnd(beforeCursor);
}

int _findLikelyPromptEnd(String beforeCursor) {
  const maxPromptSearchLength = 96;
  final searchText = beforeCursor.length > maxPromptSearchLength
      ? beforeCursor.substring(0, maxPromptSearchLength)
      : beforeCursor;
  final markerPattern = RegExp(r'(?:^|\s)(?:\S{1,80}\s+)?[#$%>]\s+');
  var promptEnd = 0;
  for (final match in markerPattern.allMatches(searchText)) {
    promptEnd = match.end;
  }
  return promptEnd;
}

/// Parsed token state for the command text before the cursor.
@visibleForTesting
class ShellCompletionTokenState {
  /// Creates a token state.
  const ShellCompletionTokenState({
    required this.words,
    required this.wordIndex,
    required this.token,
    required this.tokenStart,
  });

  /// Words before or at the cursor.
  final List<String> words;

  /// Index of [token] in [words], or the next word after trailing whitespace.
  final int wordIndex;

  /// Current token before the cursor.
  final String token;

  /// Token start offset in the command line.
  final int tokenStart;
}

/// Parses the token being edited at [cursorOffset].
@visibleForTesting
ShellCompletionTokenState? parseShellCompletionToken(
  String commandLine,
  int cursorOffset,
) {
  if (cursorOffset < 0 || cursorOffset > commandLine.length) {
    return null;
  }

  final beforeCursor = commandLine.substring(0, cursorOffset);
  final words = <String>[];
  var tokenStart = 0;
  var token = '';
  var inWord = false;
  var quote = '';
  var escaped = false;
  var sawWhitespace = false;

  for (var index = 0; index < beforeCursor.length; index++) {
    final char = beforeCursor[index];
    if (escaped) {
      escaped = false;
      if (!inWord) {
        inWord = true;
        tokenStart = index - 1;
      }
      continue;
    }
    if (char == r'\') {
      if (!inWord) {
        inWord = true;
        tokenStart = index;
      }
      escaped = true;
      continue;
    }
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      if (!inWord) {
        inWord = true;
        tokenStart = index;
      }
      quote = char;
      continue;
    }
    if (_isShellCompletionWhitespace(char)) {
      sawWhitespace = true;
      if (inWord) {
        words.add(beforeCursor.substring(tokenStart, index));
        inWord = false;
      }
      continue;
    }
    if (!inWord) {
      inWord = true;
      tokenStart = index;
    }
  }

  if (escaped || quote.isNotEmpty) {
    return null;
  }

  if (inWord) {
    token = beforeCursor.substring(tokenStart);
    words.add(token);
    return ShellCompletionTokenState(
      words: words,
      wordIndex: words.length - 1,
      token: token,
      tokenStart: tokenStart,
    );
  }

  return ShellCompletionTokenState(
    words: words,
    wordIndex: sawWhitespace ? words.length : 0,
    token: '',
    tokenStart: beforeCursor.length,
  );
}

bool _isShellCompletionWhitespace(String char) =>
    char == ' ' || char == '\t' || char == '\n' || char == '\r';

bool _containsShellQuote(String token) =>
    token.contains("'") || token.contains('"');

/// Removes simple backslash escapes from a shell token.
String normalizeShellCompletionToken(String token) {
  final builder = StringBuffer();
  var escaped = false;
  for (var index = 0; index < token.length; index++) {
    final char = token[index];
    if (escaped) {
      builder.write(char);
      escaped = false;
    } else if (char == r'\') {
      escaped = true;
    } else {
      builder.write(char);
    }
  }
  if (escaped) {
    builder.write(r'\');
  }
  return builder.toString();
}

/// Parses side-channel completion helper output.
@visibleForTesting
List<ShellCompletionSuggestion> parseShellCompletionOutput(
  String output,
  ShellCompletionInvocation invocation,
) {
  final suggestions = <ShellCompletionSuggestion>[];
  final seen = <String>{};
  var scannedLineCount = 0;

  for (final rawLine in const LineSplitter().convert(output)) {
    scannedLineCount += 1;
    if (scannedLineCount > 1200) {
      break;
    }
    final separatorIndex = rawLine.indexOf('\t');
    if (separatorIndex <= 0) {
      continue;
    }

    final rawKind = rawLine.substring(0, separatorIndex);
    final value = rawLine.substring(separatorIndex + 1).trimRight();
    if (!_isSafeCompletionValue(value)) {
      continue;
    }

    final suggestion = _suggestionFromRemoteValue(
      rawKind: rawKind,
      value: value,
      invocation: invocation,
    );
    if (suggestion == null) {
      continue;
    }

    final key =
        '${suggestion.kind.name}\u0000${suggestion.replacementStart}'
        '\u0000${suggestion.replacement}\u0000${suggestion.label}';
    if (seen.add(key)) {
      suggestions.add(suggestion);
    }
  }

  suggestions.sort(_compareShellCompletionSuggestions);
  return suggestions.length <= invocation.maxSuggestions
      ? suggestions
      : suggestions.sublist(0, invocation.maxSuggestions);
}

ShellCompletionSuggestion? _suggestionFromRemoteValue({
  required String rawKind,
  required String value,
  required ShellCompletionInvocation invocation,
}) {
  final kind = switch (rawKind) {
    'command' => ShellCompletionSuggestionKind.command,
    'directory' || 'cd_directory' => ShellCompletionSuggestionKind.directory,
    'file' => ShellCompletionSuggestionKind.file,
    _ => null,
  };
  if (kind == null) {
    return null;
  }

  final escapedValue = escapeShellCompletionToken(value);
  final directoryValue = _formatDirectoryCompletion(value);
  final escapedDirectoryValue = escapeShellCompletionToken(directoryValue);

  if (rawKind == 'cd_directory') {
    return ShellCompletionSuggestion(
      label: 'cd ${_formatDirectoryCompletionLabel(value)}',
      replacement: 'cd $escapedDirectoryValue',
      replacementStart: 0,
      replacementEnd: invocation.cursorOffset,
      kind: ShellCompletionSuggestionKind.directory,
    );
  }

  if (kind == ShellCompletionSuggestionKind.command) {
    return ShellCompletionSuggestion(
      label: value,
      replacement: escapedValue,
      replacementStart: invocation.tokenStart,
      replacementEnd: invocation.cursorOffset,
      kind: kind,
      commitSuffix: ' ',
    );
  }

  final labelPrefix = invocation.commandName == 'cd' ? 'cd ' : '';
  final replacement = kind == ShellCompletionSuggestionKind.directory
      ? escapedDirectoryValue
      : escapedValue;
  return ShellCompletionSuggestion(
    label:
        '$labelPrefix${kind == ShellCompletionSuggestionKind.directory ? _formatDirectoryCompletionLabel(value) : value}',
    replacement: replacement,
    replacementStart: invocation.tokenStart,
    replacementEnd: invocation.cursorOffset,
    kind: kind,
    commitSuffix: kind == ShellCompletionSuggestionKind.file ? ' ' : '',
  );
}

int _compareShellCompletionSuggestions(
  ShellCompletionSuggestion a,
  ShellCompletionSuggestion b,
) {
  final scoreA = _completionSuggestionScore(a);
  final scoreB = _completionSuggestionScore(b);
  if (scoreA != scoreB) {
    return scoreA.compareTo(scoreB);
  }
  return a.label.toLowerCase().compareTo(b.label.toLowerCase());
}

int _completionSuggestionScore(ShellCompletionSuggestion suggestion) {
  if (suggestion.kind == ShellCompletionSuggestionKind.command &&
      suggestion.label == 'cd') {
    return 0;
  }
  if (suggestion.label.startsWith('cd ')) {
    return 1;
  }
  return switch (suggestion.kind) {
    ShellCompletionSuggestionKind.command => 2,
    ShellCompletionSuggestionKind.directory => 3,
    ShellCompletionSuggestionKind.file => 4,
  };
}

bool _isSafeCompletionValue(String value) {
  if (value.isEmpty || value.length > 240) {
    return false;
  }
  for (var index = 0; index < value.length; index++) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit < 0x20 || codeUnit == 0x7F) {
      return false;
    }
  }
  return true;
}

String _formatDirectoryCompletion(String value) {
  if (value == '..' || value.endsWith('/')) {
    return value;
  }
  return '$value/';
}

String _formatDirectoryCompletionLabel(String value) {
  if (value == '..') {
    return value;
  }
  return _formatDirectoryCompletion(value);
}

/// Escapes a token so it can be typed safely into a POSIX-like shell.
@visibleForTesting
String escapeShellCompletionToken(String value) {
  final builder = StringBuffer();
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (_isUnescapedShellTokenChar(char)) {
      builder.write(char);
    } else {
      builder
        ..write(r'\')
        ..write(char);
    }
  }
  return builder.toString();
}

bool _isUnescapedShellTokenChar(String char) {
  final codeUnit = char.codeUnitAt(0);
  return (codeUnit >= 0x30 && codeUnit <= 0x39) ||
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A) ||
      char == '_' ||
      char == '-' ||
      char == '.' ||
      char == '/' ||
      char == '~';
}

/// Builds the remote shell helper command for a completion invocation.
@visibleForTesting
String buildShellCompletionRemoteCommand(ShellCompletionInvocation invocation) {
  final cwd = invocation.workingDirectory?.trim();
  final mode = invocation.mode.name;
  final token = invocation.token;
  final limit = invocation.maxSuggestions * 4;
  final includeCdShortcuts =
      invocation.mode == ShellCompletionMode.command &&
      'cd'.startsWith(invocation.token);

  return '''
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; export FLUTTY_MODE=${_shellQuote(mode)} FLUTTY_TOKEN=${_shellQuote(token)} FLUTTY_INCLUDE_CD_SHORTCUTS=${includeCdShortcuts ? '1' : '0'} FLUTTY_CWD=${_shellQuote(cwd ?? '')} FLUTTY_LIMIT=$limit; flutty_shell=\${SHELL:-}; flutty_shell_name=\${flutty_shell##*/}; case "\$flutty_shell_name" in bash|zsh|ksh|sh) flutty_runner=\$flutty_shell; flutty_profile_kind=\$flutty_shell_name;; *) flutty_runner=sh; flutty_profile_kind=sh;; esac; [ -n "\$flutty_runner" ] || flutty_runner=sh; FLUTTY_PROFILE_KIND=\$flutty_profile_kind "\$flutty_runner" -s <<'__FLUTTY_COMPLETION__'
case "\$FLUTTY_MODE" in
  command)
    source_if_readable() {
      [ -r "\$1" ] || return 0
      . "\$1" >/dev/null 2>&1 || :
    }
    case "\$FLUTTY_PROFILE_KIND" in
      zsh) source_if_readable "\$HOME/.zprofile"; source_if_readable "\$HOME/.zshrc" ;;
      bash) source_if_readable "\$HOME/.bash_profile"; source_if_readable "\$HOME/.bash_login"; source_if_readable "\$HOME/.profile"; source_if_readable "\$HOME/.bashrc" ;;
      *) source_if_readable "\$HOME/.profile" ;;
    esac
    ;;
esac
emulate -L sh >/dev/null 2>&1 || :
set +f
if [ -n "\$FLUTTY_CWD" ]; then
  cd -- "\$FLUTTY_CWD" 2>/dev/null || cd -- "\$HOME" 2>/dev/null || :
fi

can_emit() {
  flutty_emit_limit=\${FLUTTY_LIMIT:-96}
  flutty_emit_count=\${flutty_emit_count:-0}
  [ "\$flutty_emit_count" -lt "\$flutty_emit_limit" ] 2>/dev/null
}

emit_line() {
  can_emit || return 1
  kind=\$1
  item=\$2
  case "\$item" in
    *'
'*|*'	'*) return 0 ;;
  esac
  [ -n "\$item" ] || return 0
  flutty_emit_count=\$((flutty_emit_count + 1))
  printf '%s\\t%s\\n' "\$kind" "\$item"
  can_emit
}

emit_bash_matches() {
  mode=\$1
  token=\$2
  if [ -n "\${BASH_VERSION:-}" ] && command -v compgen >/dev/null 2>&1; then
    case "\$mode" in
      command) compgen -c -- "\$token" ;;
      directory) compgen -d -- "\$token" ;;
      path) compgen -f -- "\$token" ;;
    esac
    return
  fi
  FLUTTY_BASH_MODE=\$mode FLUTTY_BASH_TOKEN=\$token bash --noprofile --norc -c '
    case "\$FLUTTY_BASH_MODE" in
      command) compgen -c -- "\$FLUTTY_BASH_TOKEN" ;;
      directory) compgen -d -- "\$FLUTTY_BASH_TOKEN" ;;
      path) compgen -f -- "\$FLUTTY_BASH_TOKEN" ;;
    esac
  '
}

emit_zsh_command_matches() {
  token=\$1
  [ -n "\${ZSH_VERSION:-}" ] || return 1
  command -v whence >/dev/null 2>&1 || return 1
  whence -wm "\$token*" 2>/dev/null | while IFS= read -r line; do
    case "\$line" in
      *:*) item=\${line%%:*} ;;
      *) item=\$line ;;
    esac
    printf '%s\\n' "\$item"
  done
}

emit_command_fallback() {
  token=\$1
  for builtin in cd ls cat grep find git ssh scp sftp mkdir rm mv cp touch pwd; do
    can_emit || return
    case "\$builtin" in
      "\$token"*) emit_line command "\$builtin" || return ;;
    esac
  done
  old_ifs=\$IFS
  IFS=:
  for dir in \$PATH; do
    can_emit || break
    [ -d "\$dir" ] || continue
    for candidate in "\$dir"/"\$token"*; do
      can_emit || break
      [ -f "\$candidate" ] && [ -x "\$candidate" ] || continue
      emit_line command "\${candidate##*/}" || break
    done
  done
  IFS=\$old_ifs
}

emit_path_fallback() {
  mode=\$1
  token=\$2
  case "\$token" in
    */*) search_dir=\${token%/*}; base=\${token##*/}; prefix="\$search_dir/" ;;
    *) search_dir=.; base=\$token; prefix= ;;
  esac
  [ -d "\$search_dir" ] || return
  for candidate in "\$search_dir"/"\$base"*; do
    can_emit || break
    [ -e "\$candidate" ] || continue
    name=\${candidate##*/}
    item="\$prefix\$name"
    if [ -d "\$candidate" ]; then
      emit_line directory "\$item" || break
    elif [ "\$mode" = path ]; then
      emit_line file "\$item" || break
    fi
  done
}

emit_path_matches() {
  mode=\$1
  token=\$2
  if command -v bash >/dev/null 2>&1; then
    emit_bash_matches "\$mode" "\$token" 2>/dev/null | while IFS= read -r item; do
      [ -n "\$item" ] || continue
      if [ -d "\$item" ]; then
        emit_line directory "\$item" || break
      elif [ "\$mode" = path ]; then
        emit_line file "\$item" || break
      fi
    done
    return
  fi
  emit_path_fallback "\$mode" "\$token"
}

case "\$FLUTTY_MODE" in
  command)
    if [ -n "\${BASH_VERSION:-}" ] && command -v compgen >/dev/null 2>&1; then
      emit_bash_matches command "\$FLUTTY_TOKEN" 2>/dev/null | while IFS= read -r item; do
        emit_line command "\$item" || break
      done
    elif [ -n "\${ZSH_VERSION:-}" ] && command -v whence >/dev/null 2>&1; then
      emit_zsh_command_matches "\$FLUTTY_TOKEN" 2>/dev/null | while IFS= read -r item; do
        emit_line command "\$item" || break
      done
    elif command -v bash >/dev/null 2>&1; then
      emit_bash_matches command "\$FLUTTY_TOKEN" 2>/dev/null | while IFS= read -r item; do
        emit_line command "\$item" || break
      done
    else
      emit_command_fallback "\$FLUTTY_TOKEN"
    fi
    if [ "\$FLUTTY_INCLUDE_CD_SHORTCUTS" = 1 ]; then
      emit_line cd_directory ..
      emit_path_matches directory ''
    fi
    ;;
  directory)
    emit_path_matches directory "\$FLUTTY_TOKEN"
    ;;
  path)
    emit_path_matches path "\$FLUTTY_TOKEN"
    ;;
esac
__FLUTTY_COMPLETION__
''';
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
