import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tmux_state.dart';
import 'ssh_service.dart';

/// Introspects and controls tmux sessions on remote hosts via SSH exec
/// channels.
///
/// All queries use `SshSession.execute()` to avoid interfering with the
/// interactive shell. The results are parsed from tmux's `-F` format strings.
///
/// The tmux binary path is cached after first successful detection to
/// avoid redundant profile sourcing on subsequent calls.
class TmuxService {
  /// Creates a new [TmuxService].
  const TmuxService();

  /// Cached tmux binary paths per SSH session (by connectionId).
  static final Map<int, String> _tmuxPathCache = {};

  /// Clears the cached tmux path for a connection.
  void clearCache(int connectionId) => _tmuxPathCache.remove(connectionId);

  // ── Detection ──────────────────────────────────────────────────────────

  /// Returns `true` if there is at least one tmux session running on the
  /// remote host.
  ///
  /// Uses `tmux list-sessions` rather than checking the `TMUX` environment
  /// variable, because SSH exec channels do not share the interactive
  /// shell's environment.
  Future<bool> isTmuxActive(SshSession session) async {
    try {
      // Cache the tmux binary path on first successful detection.
      await _cacheTmuxPath(session);
      final output = await _exec(session, 'tmux list-sessions 2>/dev/null');
      return output.trim().isNotEmpty;
    } on Exception {
      return false;
    }
  }

  /// Returns `true` if tmux is installed on the remote host.
  Future<bool> isTmuxInstalled(SshSession session) async {
    try {
      final output = await _exec(session, 'which tmux');
      return output.trim().isNotEmpty;
    } on Exception {
      return false;
    }
  }

  // ── Session queries ────────────────────────────────────────────────────

  /// Lists all tmux sessions on the remote host.
  Future<List<TmuxSession>> listSessions(SshSession session) async {
    try {
      final output = await _exec(
        session,
        'tmux list-sessions -F '
        "'#{session_name}|#{session_windows}|"
        "#{session_attached}|#{session_activity}'",
      );
      return _parseLines(output, TmuxSession.fromTmuxFormat);
    } on Exception {
      return const [];
    }
  }

  /// Returns the name of the tmux session the user is most likely
  /// interacting with, or `null` if no session can be identified.
  ///
  /// First tries `tmux display-message` (works when the exec shell
  /// inherits the tmux context). If that fails, falls back to finding
  /// the first attached session from `tmux list-sessions` — this covers
  /// the common case where the interactive shell is inside tmux but the
  /// exec channel is not.
  Future<String?> currentSessionName(SshSession session) async {
    try {
      // Direct approach — works if the exec channel is inside tmux.
      final output = await _exec(
        session,
        "tmux display-message -p '#{session_name}'",
      );
      final name = output.trim();
      if (name.isNotEmpty) return name;
    } on Exception {
      // Fall through to fallback.
    }

    // Fallback — find the first attached session.
    try {
      final sessions = await listSessions(session);
      final attached = sessions.where((s) => s.isAttached).toList();
      if (attached.isNotEmpty) return attached.first.name;
      // If no attached session, tmux is running but user isn't in it.
      return null;
    } on Exception {
      return null;
    }
  }

  // ── Window queries ─────────────────────────────────────────────────────

  /// Lists all windows in the given tmux [sessionName].
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName,
  ) async {
    try {
      final quotedName = _shellQuote(sessionName);
      final output = await _exec(
        session,
        'tmux list-windows -t $quotedName -F '
        "'#{window_index}|#{window_name}|#{window_active}|"
        '#{pane_current_command}|#{pane_current_path}|'
        "#{window_flags}|#{pane_title}'",
      );
      return _parseLines(output, TmuxWindow.fromTmuxFormat);
    } on Exception {
      return const [];
    }
  }

  // ── Window mutations ───────────────────────────────────────────────────

  /// Creates a new window in [sessionName], optionally running [command]
  /// and/or setting a window [name].
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
  }) async {
    final parts = <String>[
      'tmux new-window -t ${_shellQuote(sessionName)}',
      if (name != null && name.trim().isNotEmpty)
        '-n ${_shellQuote(name.trim())}',
      if (command != null && command.trim().isNotEmpty)
        _shellQuote(command.trim()),
    ];
    await _exec(session, parts.join(' '));
  }

  /// Switches to window [windowIndex] in [sessionName] via exec channel.
  ///
  /// This is a tmux server operation — the server notifies all attached
  /// clients of the change, so it works correctly regardless of which
  /// channel sends the command.
  ///
  /// Uses fire-and-forget for instant response — the window switch is
  /// visible immediately in the interactive terminal PTY.
  void selectWindow(SshSession session, String sessionName, int windowIndex) {
    _execFireAndForget(
      session,
      'tmux select-window -t ${_shellQuote(sessionName)}:$windowIndex',
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Runs a command via SSH exec channel and returns stdout as a string.
  ///
  /// SSH exec channels start with a minimal PATH that may not include
  /// user-installed tools (e.g. Homebrew on macOS). The command is
  /// wrapped to source common shell profiles first so tmux is found
  /// regardless of install location.
  ///
  /// Drains both stdout and stderr to prevent SSH channel flow-control
  /// deadlocks, and awaits channel completion.
  Future<String> _exec(SshSession session, String command) async {
    // If we have a cached tmux path, rewrite bare 'tmux' to the full path.
    final cachedPath = _tmuxPathCache[session.connectionId];
    final resolvedCommand = cachedPath != null
        ? command.replaceFirst('tmux ', '$cachedPath ')
        : command;

    // Only source profiles if we don't have a cached path yet.
    final wrappedCommand = cachedPath != null
        ? resolvedCommand
        : '. ~/.profile 2>/dev/null; '
              '. ~/.bash_profile 2>/dev/null; '
              '. ~/.zprofile 2>/dev/null; '
              '$command';
    final execSession = await session.execute(wrappedCommand);
    final results = await Future.wait([
      execSession.stdout.cast<List<int>>().transform(utf8.decoder).join(),
      execSession.stderr.cast<List<int>>().transform(utf8.decoder).join(),
    ]);
    return results[0];
  }

  /// Fire-and-forget: sends a tmux command without waiting for output.
  ///
  /// Used for operations like `select-window` where the result is
  /// visible immediately in the interactive terminal. Avoids the
  /// latency of draining stdout/stderr.
  void _execFireAndForget(SshSession session, String command) {
    final cachedPath = _tmuxPathCache[session.connectionId];
    final resolvedCommand = cachedPath != null
        ? command.replaceFirst('tmux ', '$cachedPath ')
        : command;
    final wrappedCommand = cachedPath != null
        ? resolvedCommand
        : '. ~/.profile 2>/dev/null; '
              '. ~/.bash_profile 2>/dev/null; '
              '. ~/.zprofile 2>/dev/null; '
              '$command';
    // Launch and ignore — the exec channel self-closes on completion.
    session.execute(wrappedCommand).then((exec) {
      // Drain streams to prevent backpressure, but don't wait.
      exec.stdout.drain<void>();
      exec.stderr.drain<void>();
    }).ignore();
  }

  /// Resolves and caches the full path to the tmux binary.
  Future<void> _cacheTmuxPath(SshSession session) async {
    if (_tmuxPathCache.containsKey(session.connectionId)) return;
    try {
      final execSession = await session.execute(
        '. ~/.profile 2>/dev/null; '
        '. ~/.bash_profile 2>/dev/null; '
        '. ~/.zprofile 2>/dev/null; '
        'command -v tmux',
      );
      final results = await Future.wait([
        execSession.stdout.cast<List<int>>().transform(utf8.decoder).join(),
        execSession.stderr.cast<List<int>>().transform(utf8.decoder).join(),
      ]);
      final path = results[0].trim();
      if (path.isNotEmpty && path.startsWith('/')) {
        _tmuxPathCache[session.connectionId] = path;
      }
    } on Object {
      // Ignore — we'll fall back to profile sourcing.
    }
  }

  /// Parses non-empty lines from [output] using [parser].
  List<T> _parseLines<T>(String output, T Function(String) parser) {
    final lines = output.trim().split('\n');
    final results = <T>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        results.add(parser(line));
      } on FormatException {
        // Skip malformed lines.
      }
    }
    return results;
  }

  /// Single-quotes a value for safe use in shell commands.
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\"'\"'")}'";
}

/// Provider for [TmuxService].
final tmuxServiceProvider = Provider<TmuxService>((ref) => const TmuxService());
