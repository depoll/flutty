import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/tmux_state.dart';
import 'ssh_service.dart';

/// Introspects and controls tmux sessions on remote hosts via SSH exec
/// channels.
///
/// All queries use `SshSession.execute()` to avoid interfering with the
/// interactive shell. The results are parsed from tmux's `-F` format strings.
class TmuxService {
  /// Creates a new [TmuxService].
  const TmuxService();

  // ── Detection ──────────────────────────────────────────────────────────

  /// Returns `true` if the connected shell appears to be inside a tmux
  /// session.
  ///
  /// Checks by running `echo $TMUX` via an exec channel. A non-empty
  /// response means tmux is active.
  Future<bool> isTmuxActive(SshSession session) async {
    try {
      final output = await _exec(session, r'echo $TMUX');
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
        "'#{session_name}\t#{session_windows}\t"
        "#{session_attached}\t#{session_activity}'",
      );
      return _parseLines(output, TmuxSession.fromTmuxFormat);
    } on Exception {
      return const [];
    }
  }

  /// Returns the name of the tmux session the interactive shell is
  /// currently inside, or `null` if not in tmux.
  Future<String?> currentSessionName(SshSession session) async {
    try {
      final output = await _exec(
        session,
        "tmux display-message -p '#{session_name}'",
      );
      final name = output.trim();
      return name.isEmpty ? null : name;
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
        "'#{window_index}\t#{window_name}\t#{window_active}\t"
        "#{pane_current_command}\t#{pane_current_path}'",
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

  /// Builds the shell command to switch to window [windowIndex] in the
  /// current tmux session.
  ///
  /// This returns the command string rather than executing it, because
  /// window switching must be sent through the **interactive shell** (not
  /// an exec channel) so that the terminal display updates.
  String buildSelectWindowCommand(String sessionName, int windowIndex) =>
      'tmux select-window -t ${_shellQuote(sessionName)}:$windowIndex';

  // ── Helpers ────────────────────────────────────────────────────────────

  Future<String> _exec(SshSession session, String command) async {
    final execSession = await session.execute(command);
    final stdout = await execSession.stdout
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join();
    return stdout;
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
