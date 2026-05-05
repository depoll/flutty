import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diagnostics_log_service.dart';
import 'ssh_service.dart';

/// Type of completion being requested from the side-channel shell.
enum ShellCompletionMode {
  /// Complete the first command word.
  command,

  /// Complete a command argument through installed shell completions.
  argument,

  /// Complete only directories.
  directory,

  /// Complete files and directories.
  path,
}

/// Type of a single shell completion suggestion.
enum ShellCompletionSuggestionKind {
  /// A command pattern from shell history.
  history,

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
    this.shellCommand,
    this.words = const <String>[],
    this.wordIndex = 0,
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

  /// Foreground shell command to use for shell-native completion, when known.
  final String? shellCommand;

  /// Parsed shell words before or at the cursor.
  final List<String> words;

  /// Index of [token] in [words], or the next word after trailing whitespace.
  final int wordIndex;

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
  ShellCompletionService({
    this.timeout = const Duration(milliseconds: 1500),
    this.interactiveZshTimeout = const Duration(milliseconds: 1000),
    this.historyTimeout = const Duration(milliseconds: 800),
    this.maxOutputChars = 12000,
    this.maxHistoryOutputChars = 80000,
    this.cacheTtl = const Duration(seconds: 2),
    this.historyCacheTtl = const Duration(minutes: 5),
  });

  /// Maximum time to wait for a completion exec.
  final Duration timeout;

  /// Maximum time to wait for the PTY-backed zsh completion attempt.
  final Duration interactiveZshTimeout;

  /// Maximum time to wait while loading shell history.
  final Duration historyTimeout;

  /// Maximum stdout characters to buffer from the remote helper.
  final int maxOutputChars;

  /// Maximum stdout characters to buffer from the remote history helper.
  final int maxHistoryOutputChars;

  /// How long exact completion requests can be reused.
  final Duration cacheTtl;

  /// How long shell history snapshots can be reused.
  final Duration historyCacheTtl;

  final Map<String, _ShellCompletionCacheEntry> _cache =
      <String, _ShellCompletionCacheEntry>{};
  final Map<String, Future<List<ShellCompletionSuggestion>>> _inFlight =
      <String, Future<List<ShellCompletionSuggestion>>>{};
  final Map<String, _ShellHistoryCacheEntry> _historyCache =
      <String, _ShellHistoryCacheEntry>{};
  final Map<String, Future<List<String>>> _historyInFlight =
      <String, Future<List<String>>>{};

  /// Runs a completion query for [invocation].
  Future<List<ShellCompletionSuggestion>> complete(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final staticSuggestions = buildShellCompletionStaticSuggestions(invocation);
    if (staticSuggestions != null && invocation.token.isEmpty) {
      return staticSuggestions;
    }
    final allowShellFallback = invocation.token.isNotEmpty;

    final cacheKey = _shellCompletionCacheKey(session, invocation);
    final cached = _cache[cacheKey];
    final now = DateTime.now();
    if (cached != null && now.difference(cached.createdAt) <= cacheTtl) {
      return cached.suggestions;
    }

    final pending = _inFlight[cacheKey];
    if (pending != null) {
      return pending;
    }

    final future = _completeUncached(
      session,
      invocation,
      staticSuggestions,
      allowShellFallback: allowShellFallback,
    );
    _inFlight[cacheKey] = future;
    try {
      final suggestions = await future;
      _cache[cacheKey] = _ShellCompletionCacheEntry(
        createdAt: DateTime.now(),
        suggestions: List<ShellCompletionSuggestion>.unmodifiable(suggestions),
      );
      _trimCompletionCache(now);
      return suggestions;
    } finally {
      _inFlight.remove(cacheKey)?.ignore();
    }
  }

  Future<List<ShellCompletionSuggestion>> _completeUncached(
    SshSession session,
    ShellCompletionInvocation invocation,
    List<ShellCompletionSuggestion>? staticSuggestions, {
    required bool allowShellFallback,
  }) async {
    final startedAt = DateTime.now();
    final historySuggestions = await _completeFromHistory(session, invocation);
    if (historySuggestions.isNotEmpty) {
      final duration = DateTime.now().difference(startedAt);
      if (duration >= const Duration(milliseconds: 350)) {
        DiagnosticsLogService.instance.debug(
          'shell_completion',
          'history_request_complete',
          fields: {
            'connectionId': session.connectionId,
            'mode': invocation.mode.name,
            'durationMs': duration.inMilliseconds,
            'suggestionCount': historySuggestions.length,
          },
        );
      }
      return historySuggestions;
    }
    if (!allowShellFallback) {
      return const <ShellCompletionSuggestion>[];
    }

    final output = await session
        .runQueuedExec(() => _runCompletionCommand(session, invocation))
        .onError<Object>((error, stackTrace) {
          if (staticSuggestions != null) {
            return '';
          }
          Error.throwWithStackTrace(error, stackTrace);
        });
    final suggestions = parseShellCompletionOutput(output, invocation);
    final resolvedSuggestions = suggestions.isEmpty && staticSuggestions != null
        ? staticSuggestions
        : suggestions;
    final duration = DateTime.now().difference(startedAt);
    if (duration >= const Duration(milliseconds: 350)) {
      DiagnosticsLogService.instance.debug(
        'shell_completion',
        'request_complete',
        fields: {
          'connectionId': session.connectionId,
          'mode': invocation.mode.name,
          'durationMs': duration.inMilliseconds,
          'suggestionCount': resolvedSuggestions.length,
        },
      );
    }
    return resolvedSuggestions;
  }

  Future<List<ShellCompletionSuggestion>> _completeFromHistory(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    try {
      final history = await _loadShellHistory(session, invocation);
      return buildShellHistorySuggestions(history, invocation);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'shell_completion',
        'history_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return const <ShellCompletionSuggestion>[];
    }
  }

  Future<List<String>> _loadShellHistory(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final key = _shellHistoryCacheKey(session, invocation);
    final now = DateTime.now();
    final cached = _historyCache[key];
    if (cached != null && now.difference(cached.createdAt) <= historyCacheTtl) {
      return cached.commands;
    }

    final pending = _historyInFlight[key];
    if (pending != null) {
      return pending;
    }

    final future = session.runQueuedExec(
      () => _runHistoryCommand(session, invocation),
    );
    _historyInFlight[key] = future;
    try {
      final commands = await future;
      _historyCache[key] = _ShellHistoryCacheEntry(
        createdAt: DateTime.now(),
        commands: List<String>.unmodifiable(commands),
      );
      _trimHistoryCache(now);
      return commands;
    } finally {
      _historyInFlight.remove(key)?.ignore();
    }
  }

  Future<List<String>> _runHistoryCommand(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final command = buildShellHistoryRemoteCommand(invocation);
    final exec = await session.execute(command);
    try {
      final stdout = StringBuffer();
      final stdoutFuture = exec.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .forEach((chunk) {
            if (stdout.length >= maxHistoryOutputChars) {
              return;
            }
            final remaining = maxHistoryOutputChars - stdout.length;
            stdout.write(
              chunk.length <= remaining ? chunk : chunk.substring(0, remaining),
            );
          });
      final stderrFuture = exec.stderr.drain<void>();
      await Future.wait<void>([
        stdoutFuture,
        stderrFuture,
        exec.done,
      ]).timeout(historyTimeout);
      return parseShellHistoryOutput(stdout.toString());
    } on TimeoutException {
      DiagnosticsLogService.instance.debug(
        'shell_completion',
        'history_timeout',
        fields: {
          'connectionId': session.connectionId,
          'timeoutMs': historyTimeout.inMilliseconds,
        },
      );
      rethrow;
    } finally {
      exec.close();
    }
  }

  Future<String> _runCompletionCommand(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    if (_shouldTryInteractiveZshCompletion(invocation)) {
      try {
        final result = await _runInteractiveZshCompletionCommand(
          session,
          invocation,
        );
        if (result.didComplete) {
          return result.output;
        }
      } on Object catch (error) {
        DiagnosticsLogService.instance.debug(
          'shell_completion',
          'interactive_zsh_unavailable',
          fields: {
            'connectionId': session.connectionId,
            'errorType': error.runtimeType,
          },
        );
      }
    }

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

  Future<_InteractiveCompletionResult> _runInteractiveZshCompletionCommand(
    SshSession session,
    ShellCompletionInvocation invocation,
  ) async {
    final command = buildInteractiveZshCompletionRemoteCommand(invocation);
    final exec = await session.execute(command, pty: const SSHPtyConfig());
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
      exec.write(utf8.encode(buildInteractiveZshCompletionInput(invocation)));
      await exec.stdin.close();
      await Future.wait<void>([
        stdoutFuture,
        stderrFuture,
        exec.done,
      ]).timeout(interactiveZshTimeout);
      final output = stdout.toString();
      return _InteractiveCompletionResult(
        output: output,
        didComplete: _containsInteractiveZshCompletionDoneMarker(output),
      );
    } finally {
      exec.close();
    }
  }

  void _trimCompletionCache(DateTime now) {
    _cache.removeWhere(
      (key, value) => now.difference(value.createdAt) > cacheTtl,
    );
    const maxEntries = 64;
    if (_cache.length <= maxEntries) {
      return;
    }
    final overflow = _cache.length - maxEntries;
    final keysToRemove = _cache.keys.take(overflow).toList(growable: false);
    for (final key in keysToRemove) {
      _cache.remove(key);
    }
  }

  void _trimHistoryCache(DateTime now) {
    _historyCache.removeWhere(
      (key, value) => now.difference(value.createdAt) > historyCacheTtl,
    );
    const maxEntries = 24;
    if (_historyCache.length <= maxEntries) {
      return;
    }
    final overflow = _historyCache.length - maxEntries;
    final keysToRemove = _historyCache.keys
        .take(overflow)
        .toList(growable: false);
    for (final key in keysToRemove) {
      _historyCache.remove(key);
    }
  }
}

class _ShellCompletionCacheEntry {
  const _ShellCompletionCacheEntry({
    required this.createdAt,
    required this.suggestions,
  });

  final DateTime createdAt;
  final List<ShellCompletionSuggestion> suggestions;
}

class _InteractiveCompletionResult {
  const _InteractiveCompletionResult({
    required this.output,
    required this.didComplete,
  });

  final String output;
  final bool didComplete;
}

class _ShellHistoryCacheEntry {
  const _ShellHistoryCacheEntry({
    required this.createdAt,
    required this.commands,
  });

  final DateTime createdAt;
  final List<String> commands;
}

String _shellCompletionCacheKey(
  SshSession session,
  ShellCompletionInvocation invocation,
) => [
  session.connectionId,
  invocation.mode.name,
  invocation.workingDirectory ?? '',
  invocation.shellCommand ?? '',
  invocation.commandLine,
  invocation.cursorOffset,
  invocation.tokenStart,
  invocation.token,
  invocation.maxSuggestions,
].join('\u001f');

String _shellHistoryCacheKey(
  SshSession session,
  ShellCompletionInvocation invocation,
) => [session.connectionId, invocation.shellCommand ?? ''].join('\u001f');

/// Provider for [ShellCompletionService].
final shellCompletionServiceProvider = Provider<ShellCompletionService>(
  (ref) => ShellCompletionService(),
);

/// Builds a completion invocation from a rendered terminal line snapshot.
ShellCompletionInvocation? buildShellCompletionInvocation({
  required String terminalText,
  required int terminalCursorOffset,
  String? promptPrefix,
  String? workingDirectory,
  String? shellCommand,
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
      : _shellCompletionArgumentMode(
          commandName: commandName,
          wordIndex: tokenState.wordIndex,
        );
  final normalizedToken = normalizeShellCompletionToken(tokenState.token);

  if (mode == ShellCompletionMode.command && normalizedToken.length < 2) {
    return null;
  }

  final normalizedWords = tokenState.words
      .map(normalizeShellCompletionToken)
      .toList(growable: false);

  return ShellCompletionInvocation(
    commandLine: commandLine,
    cursorOffset: cursorOffset,
    token: normalizedToken,
    tokenStart: tokenState.tokenStart,
    mode: mode,
    commandName: commandName,
    shellCommand: shellCommand,
    words: normalizedWords,
    wordIndex: tokenState.wordIndex,
    workingDirectory: workingDirectory,
    maxSuggestions: maxSuggestions,
  );
}

ShellCompletionMode _shellCompletionArgumentMode({
  required String? commandName,
  required int wordIndex,
}) {
  if (commandName == 'cd') {
    return ShellCompletionMode.directory;
  }
  return ShellCompletionMode.argument;
}

/// Builds local static suggestions for completion modes that do not need SSH.
///
/// Returns `null` when no static provider owns [invocation], and an empty list
/// when a provider exists but the current token has no matches.
List<ShellCompletionSuggestion>? buildShellCompletionStaticSuggestions(
  ShellCompletionInvocation invocation,
) {
  if (invocation.mode != ShellCompletionMode.argument ||
      invocation.wordIndex != 1) {
    return null;
  }

  final commandName = _normalizeShellCompletionCommandName(
    invocation.commandName,
  );
  final subcommands = _staticSubcommandsFor(commandName);
  if (commandName == null || subcommands == null) {
    return null;
  }

  final suggestions = <ShellCompletionSuggestion>[];
  for (final subcommand in subcommands) {
    if (!subcommand.startsWith(invocation.token)) {
      continue;
    }
    suggestions.add(
      ShellCompletionSuggestion(
        label: '$commandName $subcommand',
        replacement: escapeShellCompletionToken(subcommand),
        replacementStart: invocation.tokenStart,
        replacementEnd: invocation.cursorOffset,
        kind: ShellCompletionSuggestionKind.command,
        commitSuffix: ' ',
      ),
    );
    if (suggestions.length >= invocation.maxSuggestions) {
      break;
    }
  }

  return suggestions;
}

/// Builds command-line suggestions from normalized shell history patterns.
@visibleForTesting
List<ShellCompletionSuggestion> buildShellHistorySuggestions(
  List<String> historyCommands,
  ShellCompletionInvocation invocation,
) {
  final typedCommand = invocation.commandLine.substring(
    0,
    invocation.cursorOffset,
  );
  if (typedCommand.trim().isEmpty) {
    return const <ShellCompletionSuggestion>[];
  }

  final suggestions = <ShellCompletionSuggestion>[];
  final seen = <String>{};
  for (final rawCommand in historyCommands.reversed) {
    final pattern = normalizeShellHistoryCommandPattern(rawCommand);
    if (pattern == null ||
        pattern == typedCommand ||
        !pattern.startsWith(typedCommand) ||
        !seen.add(pattern)) {
      continue;
    }
    suggestions.add(
      ShellCompletionSuggestion(
        label: pattern,
        replacement: pattern,
        replacementStart: 0,
        replacementEnd: invocation.cursorOffset,
        kind: ShellCompletionSuggestionKind.history,
      ),
    );
    if (suggestions.length >= invocation.maxSuggestions) {
      break;
    }
  }

  return suggestions;
}

List<String>? _staticSubcommandsFor(String? commandName) =>
    _shellCompletionStaticSubcommands[_normalizeShellCompletionCommandName(
      commandName,
    )];

String? _normalizeShellCompletionCommandName(String? commandName) {
  var normalized = commandName?.trim();
  if (normalized == null || normalized.isEmpty) {
    return null;
  }
  normalized = normalized.split('/').last;
  if (normalized.startsWith('-')) {
    normalized = normalized.substring(1);
  }
  return normalized;
}

const _shellCompletionStaticSubcommands = <String, List<String>>{
  'tmux': <String>[
    'attach',
    'attach-session',
    'new',
    'new-session',
    'ls',
    'list-sessions',
    'new-window',
    'split-window',
    'kill-pane',
    'kill-session',
    'kill-window',
    'switch-client',
    'detach',
    'detach-client',
    'source-file',
    'rename-session',
    'rename-window',
    'display-message',
    'list-windows',
    'list-panes',
    'select-window',
    'select-pane',
    'send-keys',
    'copy-mode',
  ],
};

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

/// Normalizes a shell history command into a reusable command pattern.
@visibleForTesting
String? normalizeShellHistoryCommandPattern(String command) {
  final decoded = _decodeShellHistoryCommand(command).trim();
  if (!_isSafeHistoryCommand(decoded)) {
    return null;
  }

  final tokens = _parseShellHistoryCommandTokens(decoded);
  if (tokens == null || tokens.isEmpty) {
    return null;
  }

  final patternTokens = <String>[];
  var trimNextOptionArgument = false;
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    final tokenValue = token.value;
    if (trimNextOptionArgument) {
      trimNextOptionArgument = false;
      if (!_isShellHistoryOptionToken(tokenValue)) {
        continue;
      }
    }
    final optionPattern = _trimShellHistoryOptionValue(token.value);
    if (optionPattern != null) {
      patternTokens.add(optionPattern);
      continue;
    }
    if (_isShellHistoryOptionToken(tokenValue)) {
      patternTokens.add(tokenValue);
      trimNextOptionArgument = true;
      continue;
    }
    if (token.wasQuoted && index > 0) {
      continue;
    }
    patternTokens.add(tokenValue);
  }

  if (patternTokens.isEmpty) {
    return null;
  }

  final pattern = patternTokens
      .where((token) => token.isNotEmpty)
      .map(escapeShellCompletionToken)
      .join(' ')
      .trim();
  return pattern.isEmpty || pattern.length > 512 ? null : pattern;
}

String _decodeShellHistoryCommand(String command) {
  if (command.startsWith(': ')) {
    final separatorIndex = command.indexOf(';');
    if (separatorIndex >= 0 && separatorIndex + 1 < command.length) {
      return command.substring(separatorIndex + 1);
    }
  }
  return command;
}

bool _isSafeHistoryCommand(String command) {
  if (command.isEmpty || command.length > 1024) {
    return false;
  }
  for (var index = 0; index < command.length; index++) {
    final codeUnit = command.codeUnitAt(index);
    if (codeUnit < 0x20 || codeUnit == 0x7F) {
      return false;
    }
  }
  return true;
}

String? _trimShellHistoryOptionValue(String token) {
  if (!_isShellHistoryOptionToken(token)) {
    return null;
  }
  final separatorIndex = token.indexOf('=');
  if (separatorIndex <= 1) {
    return null;
  }
  return token.substring(0, separatorIndex);
}

bool _isShellHistoryOptionToken(String token) =>
    token.startsWith('-') && token != '-' && token != '--';

class _ShellHistoryToken {
  const _ShellHistoryToken({required this.value, required this.wasQuoted});

  final String value;
  final bool wasQuoted;
}

List<_ShellHistoryToken>? _parseShellHistoryCommandTokens(String command) {
  final tokens = <_ShellHistoryToken>[];
  final builder = StringBuffer();
  var inWord = false;
  var quote = '';
  var escaped = false;
  var tokenWasQuoted = false;

  void finishToken() {
    if (!inWord) {
      return;
    }
    tokens.add(
      _ShellHistoryToken(value: builder.toString(), wasQuoted: tokenWasQuoted),
    );
    builder.clear();
    inWord = false;
    tokenWasQuoted = false;
  }

  for (var index = 0; index < command.length; index++) {
    final char = command[index];
    if (escaped) {
      builder.write(char);
      escaped = false;
      continue;
    }
    if (char == r'\') {
      inWord = true;
      escaped = true;
      continue;
    }
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      } else {
        builder.write(char);
      }
      continue;
    }
    if (char == "'" || char == '"') {
      inWord = true;
      quote = char;
      tokenWasQuoted = true;
      continue;
    }
    if (_isShellCompletionWhitespace(char)) {
      finishToken();
      continue;
    }
    inWord = true;
    builder.write(char);
  }

  if (escaped || quote.isNotEmpty) {
    return null;
  }
  finishToken();
  return tokens;
}

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
    'argument' => ShellCompletionSuggestionKind.command,
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

  if (rawKind == 'argument') {
    final commandName = _normalizeShellCompletionCommandName(
      invocation.commandName,
    );
    return ShellCompletionSuggestion(
      label: commandName == null ? value : '$commandName $value',
      replacement: escapedValue,
      replacementStart: invocation.tokenStart,
      replacementEnd: invocation.cursorOffset,
      kind: kind,
      commitSuffix: ' ',
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
    ShellCompletionSuggestionKind.history => 2,
    ShellCompletionSuggestionKind.command => 3,
    ShellCompletionSuggestionKind.directory => 4,
    ShellCompletionSuggestionKind.file => 5,
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

const _interactiveZshCompletionDoneMarker = '__FLUTTY_ZSH_NATIVE_DONE__';
const _shellHistoryDoneMarker = '__FLUTTY_HISTORY_DONE__';

bool _shouldTryInteractiveZshCompletion(ShellCompletionInvocation invocation) =>
    invocation.mode != ShellCompletionMode.command;

bool _containsInteractiveZshCompletionDoneMarker(String output) {
  for (final rawLine in const LineSplitter().convert(output)) {
    if (rawLine.replaceAll('\r', '').trim() ==
        _interactiveZshCompletionDoneMarker) {
      return true;
    }
  }
  return false;
}

/// Builds the remote command that reads recent shell history.
@visibleForTesting
String buildShellHistoryRemoteCommand(ShellCompletionInvocation invocation) {
  final preferredShell = invocation.shellCommand?.trim() ?? '';
  return '''
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; export FLUTTY_PREFERRED_SHELL=${_shellQuote(preferredShell)}; flutty_shell=\${FLUTTY_PREFERRED_SHELL:-\${SHELL:-}}; flutty_shell_name=\${flutty_shell##*/}; emit_history_file() { flutty_source=\$1; flutty_path=\$2; [ -r "\$flutty_path" ] || return 0; tail -n 1200 "\$flutty_path" 2>/dev/null | while IFS= read -r flutty_line; do printf '%s\\t%s\\n' "\$flutty_source" "\$flutty_line"; done; }; printf '__FLUTTY_HISTORY_START__\\n'; case "\$flutty_shell_name" in zsh) emit_history_file zsh "\${HISTFILE:-\$HOME/.zsh_history}";; bash) emit_history_file bash "\${HISTFILE:-\$HOME/.bash_history}";; fish) emit_history_file fish "\${XDG_DATA_HOME:-\$HOME/.local/share}/fish/fish_history";; *) emit_history_file zsh "\$HOME/.zsh_history"; emit_history_file bash "\$HOME/.bash_history"; emit_history_file fish "\${XDG_DATA_HOME:-\$HOME/.local/share}/fish/fish_history";; esac; printf '$_shellHistoryDoneMarker\\n'
''';
}

/// Parses recent shell history emitted by [buildShellHistoryRemoteCommand].
@visibleForTesting
List<String> parseShellHistoryOutput(String output) {
  final commands = <String>[];
  var scannedLineCount = 0;
  for (final rawLine in const LineSplitter().convert(output)) {
    scannedLineCount += 1;
    if (scannedLineCount > 1600) {
      break;
    }
    final line = rawLine.replaceAll('\r', '');
    if (line.isEmpty ||
        line == '__FLUTTY_HISTORY_START__' ||
        line == _shellHistoryDoneMarker) {
      continue;
    }
    final separatorIndex = line.indexOf('\t');
    if (separatorIndex <= 0) {
      continue;
    }
    final source = line.substring(0, separatorIndex);
    final value = line.substring(separatorIndex + 1);
    final command = _historyCommandFromSource(source, value);
    if (command != null) {
      commands.add(command);
    }
  }
  return commands;
}

String? _historyCommandFromSource(String source, String value) {
  final command = switch (source) {
    'zsh' => _decodeShellHistoryCommand(value),
    'bash' => value,
    'fish' => _decodeFishHistoryCommand(value),
    _ => null,
  };
  if (command == null) {
    return null;
  }
  final trimmed = command.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _decodeFishHistoryCommand(String value) {
  const prefix = '- cmd: ';
  if (!value.startsWith(prefix)) {
    return null;
  }
  return value.substring(prefix.length).replaceAll(r'\n', ' ');
}

/// Builds the remote command that starts a PTY-backed zsh completion shell.
@visibleForTesting
String buildInteractiveZshCompletionRemoteCommand(
  ShellCompletionInvocation invocation,
) {
  final cwd = invocation.workingDirectory?.trim();
  final preferredShell = invocation.shellCommand?.trim() ?? '';
  final mode = invocation.mode.name;
  final setupScript = _interactiveZshCompletionSetupScript();
  return '''
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; stty -echo 2>/dev/null || :; export FLUTTY_CWD=${_shellQuote(cwd ?? '')} FLUTTY_PREFERRED_SHELL=${_shellQuote(preferredShell)} FLUTTY_MODE=${_shellQuote(mode)}; flutty_shell=\${FLUTTY_PREFERRED_SHELL:-\${SHELL:-}}; flutty_shell_name=\${flutty_shell##*/}; case "\$flutty_shell_name" in zsh) if [ -x "\$flutty_shell" ]; then flutty_runner=\$flutty_shell; else flutty_runner=\$(command -v zsh 2>/dev/null || :); fi;; *) exit 78;; esac; [ -n "\$flutty_runner" ] || exit 78; if [ -n "\$FLUTTY_CWD" ]; then cd -- "\$FLUTTY_CWD" 2>/dev/null || cd -- "\$HOME" 2>/dev/null || :; fi; flutty_setup=\$(mktemp "\${TMPDIR:-/tmp}/flutty-zsh-completion.XXXXXX") || exit 78; cat >"\$flutty_setup" <<'__FLUTTY_ZSH_COMPLETION_SETUP__'
$setupScript
__FLUTTY_ZSH_COMPLETION_SETUP__
export FLUTTY_ZSH_COMPLETION_SETUP="\$flutty_setup"; exec "\$flutty_runner" -fi
''';
}

/// Builds stdin sent to the PTY-backed zsh completion shell.
@visibleForTesting
String buildInteractiveZshCompletionInput(
  ShellCompletionInvocation invocation,
) {
  final commandLine = invocation.commandLine;
  return '''
source "\$FLUTTY_ZSH_COMPLETION_SETUP" >/dev/null 2>&1 || exit 78
$commandLine\t''';
}

String _interactiveZshCompletionSetupScript() =>
    '''
source_if_readable() {
  [ -r "\$1" ] || return 0
  . "\$1" >/dev/null 2>&1 || :
}
TRAPEXIT() {
  rm -f "\${FLUTTY_ZSH_COMPLETION_SETUP:-}" 2>/dev/null || :
}
source_if_readable "\$HOME/.zprofile"
source_if_readable "\$HOME/.zshrc"
autoload -Uz compinit
compinit -C >/dev/null 2>&1 || compinit -u >/dev/null 2>&1 || :
zstyle ':completion:*' verbose no
zstyle ':completion:*' group-name ''
zstyle ':completion:*' format ''
emit_native_completion_item() {
  local item=\$1
  case "\$FLUTTY_MODE" in
    directory)
      [ -d "\$item" ] && printf 'directory\\t%s\\n' "\$item"
      ;;
    path)
      if [ -d "\$item" ]; then
        printf 'directory\\t%s\\n' "\$item"
      elif [ -e "\$item" ]; then
        printf 'file\\t%s\\n' "\$item"
      fi
      ;;
    *)
      if [ -d "\$item" ]; then
        printf 'directory\\t%s\\n' "\$item"
      elif [ -e "\$item" ]; then
        printf 'file\\t%s\\n' "\$item"
      else
        printf 'argument\\t%s\\n' "\$item"
      fi
      ;;
  esac
}
_flutty_dump_completions() {
  typeset -ga _flutty_matches
  _flutty_matches=()
  compadd() {
    local -a original_args capture_args out
    original_args=("\$@")
    while (( \$# )); do
      case "\$1" in
        -O|-A)
          shift 2
          ;;
        -O*|-A*)
          shift
          ;;
        *)
          capture_args+=("\$1")
          shift
          ;;
      esac
    done
    builtin compadd -O out "\${capture_args[@]}" 2>/dev/null || :
    _flutty_matches+=("\${out[@]}")
    builtin compadd "\${original_args[@]}" 2>/dev/null
    local status=\$?
    return \$status
  }
  _main_complete >/dev/null 2>&1 || :
  print -r -- __FLUTTY_ZSH_NATIVE_START__
  local item
  for item in "\${_flutty_matches[@]}"; do
    emit_native_completion_item "\$item"
  done
  print -r -- $_interactiveZshCompletionDoneMarker
  exit 0
}
zle -C _flutty_complete complete-word _flutty_dump_completions
bindkey "^I" _flutty_complete
''';

/// Builds the remote shell helper command for a completion invocation.
@visibleForTesting
String buildShellCompletionRemoteCommand(ShellCompletionInvocation invocation) {
  final cwd = invocation.workingDirectory?.trim();
  final mode = invocation.mode.name;
  final token = invocation.token;
  final limit = invocation.maxSuggestions * 4;
  final commandName =
      _normalizeShellCompletionCommandName(invocation.commandName) ?? '';
  final compWordsAssignment = _bashCompWordsAssignment(invocation);
  final preferredShell = invocation.shellCommand?.trim() ?? '';
  final includeCdShortcuts =
      invocation.mode == ShellCompletionMode.command &&
      'cd'.startsWith(invocation.token);

  return '''
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; export FLUTTY_MODE=${_shellQuote(mode)} FLUTTY_TOKEN=${_shellQuote(token)} FLUTTY_COMMAND_NAME=${_shellQuote(commandName)} FLUTTY_COMMAND_LINE=${_shellQuote(invocation.commandLine)} FLUTTY_CURSOR_OFFSET=${invocation.cursorOffset} FLUTTY_WORD_INDEX=${invocation.wordIndex} FLUTTY_COMP_WORDS_ASSIGNMENT=${_shellQuote(compWordsAssignment)} FLUTTY_INCLUDE_CD_SHORTCUTS=${includeCdShortcuts ? '1' : '0'} FLUTTY_CWD=${_shellQuote(cwd ?? '')} FLUTTY_LIMIT=$limit FLUTTY_PREFERRED_SHELL=${_shellQuote(preferredShell)}; flutty_shell=\${FLUTTY_PREFERRED_SHELL:-\${SHELL:-}}; flutty_shell_name=\${flutty_shell##*/}; case "\$flutty_shell_name" in bash|zsh|ksh|sh) if [ -x "\$flutty_shell" ]; then flutty_runner=\$flutty_shell; else flutty_runner=\$(command -v "\$flutty_shell_name" 2>/dev/null || printf %s "\$flutty_shell_name"); fi; flutty_profile_kind=\$flutty_shell_name;; *) flutty_runner=sh; flutty_profile_kind=sh;; esac; [ -n "\$flutty_runner" ] || flutty_runner=sh; FLUTTY_PROFILE_KIND=\$flutty_profile_kind "\$flutty_runner" -s <<'__FLUTTY_COMPLETION__'
case "\$FLUTTY_MODE:\$FLUTTY_PROFILE_KIND" in
  command:*|argument:bash)
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

emit_bash_programmable_argument_matches() {
  command -v bash >/dev/null 2>&1 || return 1
  bash --noprofile --norc -s <<'__FLUTTY_BASH_COMPLETION__'
source_if_readable() {
  [ -r "\$1" ] || return 0
  . "\$1" >/dev/null 2>&1 || :
}

source_if_readable "\$HOME/.bash_profile"
source_if_readable "\$HOME/.bash_login"
source_if_readable "\$HOME/.profile"
source_if_readable "\$HOME/.bashrc"
source_if_readable /etc/bash_completion
source_if_readable /usr/share/bash-completion/bash_completion
source_if_readable /opt/homebrew/etc/profile.d/bash_completion.sh
source_if_readable /usr/local/etc/profile.d/bash_completion.sh
source_if_readable /opt/local/etc/profile.d/bash_completion.sh

eval "\$FLUTTY_COMP_WORDS_ASSIGNMENT" 2>/dev/null || exit 1
COMP_LINE=\${FLUTTY_COMMAND_LINE:-}
COMP_POINT=\${FLUTTY_CURSOR_OFFSET:-0}
COMP_TYPE=9
COMP_KEY=9
COMP_CWORD=\${FLUTTY_WORD_INDEX:-0}
cur=\${COMP_WORDS[\$COMP_CWORD]:-}
prev=
if [ "\$COMP_CWORD" -gt 0 ] 2>/dev/null; then
  prev=\${COMP_WORDS[\$((COMP_CWORD - 1))]:-}
fi
cmd=\${FLUTTY_COMMAND_NAME:-\${COMP_WORDS[0]:-}}
[ -n "\$cmd" ] || exit 1

if ! complete -p "\$cmd" >/dev/null 2>&1; then
  if declare -F _completion_loader >/dev/null 2>&1; then
    _completion_loader "\$cmd" >/dev/null 2>&1 || :
  fi
fi
spec=\$(complete -p "\$cmd" 2>/dev/null || complete -p -D 2>/dev/null) ||
  exit 1

set -f
eval "set -- \$spec" 2>/dev/null || exit 1
comp_function=
comp_command=
comp_words=
comp_action=
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -F)
      shift
      comp_function=\${1:-}
      ;;
    -C)
      shift
      comp_command=\${1:-}
      ;;
    -W)
      shift
      comp_words=\${1:-}
      ;;
    -A)
      shift
      comp_action=\${1:-}
      ;;
  esac
  shift || break
done

if [ -n "\$comp_function" ] && declare -F "\$comp_function" >/dev/null 2>&1; then
  COMPREPLY=()
  "\$comp_function" "\$cmd" "\$cur" "\$prev" >/dev/null 2>&1 || :
  [ "\${#COMPREPLY[@]}" -gt 0 ] || exit 1
  printf '%s\n' "\${COMPREPLY[@]}"
elif [ -n "\$comp_command" ] && command -v "\$comp_command" >/dev/null 2>&1; then
  "\$comp_command" "\$cmd" "\$cur" "\$prev" 2>/dev/null
elif [ -n "\$comp_words" ]; then
  compgen -W "\$comp_words" -- "\$cur"
elif [ -n "\$comp_action" ]; then
  compgen -A "\$comp_action" -- "\$cur"
else
  exit 1
fi
__FLUTTY_BASH_COMPLETION__
}

emit_dynamic_argument_matches() {
  dynamic_output=\$(emit_bash_programmable_argument_matches 2>/dev/null)
  [ -n "\$dynamic_output" ] || return 1
  printf '%s\\n' "\$dynamic_output" | while IFS= read -r item; do
    [ -n "\$item" ] || continue
    if [ -d "\$item" ]; then
      emit_line directory "\$item" || break
    elif [ -e "\$item" ]; then
      emit_line file "\$item" || break
    else
      emit_line argument "\$item" || break
    fi
  done
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
  argument)
    if ! emit_dynamic_argument_matches && [ -n "\$FLUTTY_TOKEN" ]; then
      emit_path_matches path "\$FLUTTY_TOKEN"
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

String _bashCompWordsAssignment(ShellCompletionInvocation invocation) {
  final words = invocation.words.isEmpty && invocation.commandName != null
      ? <String>[normalizeShellCompletionToken(invocation.commandName!)]
      : invocation.words.toList(growable: true);
  while (words.length <= invocation.wordIndex) {
    words.add('');
  }
  if (invocation.wordIndex >= 0 && invocation.wordIndex < words.length) {
    words[invocation.wordIndex] = invocation.token;
  }
  return 'COMP_WORDS=(${words.map(_shellQuote).join(' ')})';
}

String _shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";
