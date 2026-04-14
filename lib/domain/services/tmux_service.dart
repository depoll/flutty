import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
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

  /// Cached profile source commands per SSH session.
  static final Map<int, String> _profileSourceCache = {};

  static final Map<_TmuxWindowWatchKey, _TmuxWindowChangeObserver>
  _windowObservers = {};

  /// Clears the cached tmux path for a connection.
  void clearCache(int connectionId) {
    _tmuxPathCache.remove(connectionId);
    _profileSourceCache.remove(connectionId);
    final observerKeys = _windowObservers.keys
        .where((key) => key.connectionId == connectionId)
        .toList(growable: false);
    for (final key in observerKeys) {
      unawaited(_windowObservers.remove(key)?.dispose());
    }
  }

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
      final cachedTmuxPath = _tmuxPathCache[session.connectionId];
      if (cachedTmuxPath != null && cachedTmuxPath.isNotEmpty) {
        return true;
      }
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

    // Fallback — find attached sessions.
    try {
      final sessions = await listSessions(session);
      final attached = sessions.where((s) => s.isAttached).toList();
      if (attached.length == 1) return attached.first.name;
      // Multiple attached sessions are ambiguous — we can't determine
      // which one belongs to this terminal connection. Return null to
      // avoid targeting the wrong session with destructive operations.
      return null;
    } on Exception {
      return null;
    }
  }

  /// Returns `true` if [sessionName] exists on the remote tmux server.
  Future<bool> hasSession(SshSession session, String sessionName) async {
    try {
      await _cacheTmuxPath(session);
      final output = await _exec(
        session,
        'tmux has-session -t ${_shellQuote(sessionName)} 2>/dev/null && printf 1',
      );
      return output.trim() == '1';
    } on Exception {
      return false;
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
        "#{window_flags}|#{pane_title}|#{window_activity}'",
      );
      return _parseLines(output, TmuxWindow.fromTmuxFormat);
    } on Exception {
      return const [];
    }
  }

  /// Watches tmux control-mode notifications that indicate window state
  /// has changed for [sessionName].
  Stream<void> watchWindowChanges(SshSession session, String sessionName) {
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
    );
    final observer = _windowObservers.putIfAbsent(
      key,
      () => _TmuxWindowChangeObserver(
        service: this,
        session: session,
        sessionName: sessionName,
        onDispose: () => _windowObservers.remove(key),
      ),
    );
    return observer.stream;
  }

  // ── Window mutations ───────────────────────────────────────────────────

  /// Creates a new window in [sessionName], optionally running [command],
  /// setting a window [name], and/or starting in [workingDirectory].
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
    String? workingDirectory,
  }) async {
    // Don't pass -c unless an explicit workingDirectory was provided
    // (e.g. resuming an AI session in a specific project). Without -c,
    // tmux uses the session's default-directory — matching Ctrl+b,c.
    final parts = <String>[
      'tmux new-window -t ${_shellQuote(sessionName)}',
      if (workingDirectory != null && workingDirectory.trim().isNotEmpty)
        '-c ${_shellQuote(workingDirectory.trim())}',
      if (name != null && name.trim().isNotEmpty)
        '-n ${_shellQuote(name.trim())}',
    ];
    await _exec(session, parts.join(' '));

    // If a command was requested, type it into the new window's shell.
    // This ensures the command runs inside the login shell environment
    // where CLI tools installed via Homebrew/nvm/etc. are available.
    if (command != null && command.trim().isNotEmpty) {
      _execFireAndForget(
        session,
        'tmux send-keys -t ${_shellQuote(sessionName)} '
        '${_shellQuote(command.trim())} Enter',
      );
    }
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

  /// Closes a window in [sessionName] via exec channel.
  ///
  /// Uses fire-and-forget — if this was the last window, the tmux session
  /// ends and the interactive shell exits naturally.
  void killWindow(SshSession session, String sessionName, int windowIndex) {
    _execFireAndForget(
      session,
      'tmux kill-window -t ${_shellQuote(sessionName)}:$windowIndex',
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Returns the profile source prefix for this session's login shell.
  ///
  /// Only sources the profile file appropriate for the user's shell:
  /// - zsh: `~/.zprofile`
  /// - bash: `~/.bash_profile` (falls back to `~/.profile`)
  /// - sh/other: `~/.profile`
  String _profilePrefix(int connectionId) {
    final cached = _profileSourceCache[connectionId];
    if (cached != null) return cached;
    // Fallback — source all common profiles until shell is detected.
    // Redirect stdout to avoid profile greeting/MOTD output corrupting
    // our parsed command results.
    return '{ . ~/.profile; . ~/.bash_profile; . ~/.zprofile; } '
        '>/dev/null 2>&1; ';
  }

  /// Wraps [command] with profile sourcing or cached path substitution.
  String _wrapCommand(SshSession session, String command) {
    final utf8Command = _forceUtf8TmuxCommand(command);
    final cachedPath = _tmuxPathCache[session.connectionId];
    final prefixedCommand = cachedPath != null
        ? utf8Command.replaceFirst('tmux -u ', '$cachedPath -u ')
        : utf8Command;
    // Always source the login-shell profile so locale- and PATH-related tmux
    // settings stay consistent even after the binary path is cached.
    return '${_profilePrefix(session.connectionId)}'
        'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; '
        '$prefixedCommand';
  }

  String _forceUtf8TmuxCommand(String command) {
    final trimmed = command.trimLeft();
    if (!trimmed.startsWith('tmux ')) return command;
    return command.replaceFirst('tmux ', 'tmux -u ');
  }

  /// Runs a command via SSH exec channel and returns stdout as a string.
  ///
  /// Uses the cached tmux binary path when available; otherwise sources
  /// the user's login shell profile to resolve the PATH.
  ///
  /// Drains both stdout and stderr to prevent SSH channel flow-control
  /// deadlocks, and awaits channel completion.
  Future<String> _exec(SshSession session, String command) async {
    final wrappedCommand = _wrapCommand(session, command);
    final execSession = await session.execute(wrappedCommand);
    try {
      final results = await Future.wait([
        execSession.stdout.cast<List<int>>().transform(utf8.decoder).join(),
        execSession.stderr.cast<List<int>>().transform(utf8.decoder).join(),
      ]).timeout(const Duration(seconds: 10), onTimeout: () => ['', '']);
      return results[0];
    } finally {
      execSession.close();
    }
  }

  /// Fire-and-forget: sends a tmux command without waiting for output.
  ///
  /// Used for operations like `select-window` where the result is
  /// visible immediately in the interactive terminal. Avoids the
  /// latency of draining stdout/stderr.
  void _execFireAndForget(SshSession session, String command) {
    final wrappedCommand = _wrapCommand(session, command);
    // Launch and ignore — the exec channel self-closes on completion.
    session.execute(wrappedCommand).then((exec) {
      // Drain streams to prevent backpressure, but don't wait.
      exec.stdout.drain<void>().ignore();
      exec.stderr.drain<void>().ignore();
    }).ignore();
  }

  /// Detects the user's login shell and resolves the tmux binary path.
  ///
  /// Caches both the shell-specific profile source command and the
  /// full tmux path for subsequent calls.
  Future<void> _cacheTmuxPath(SshSession session) async {
    if (_tmuxPathCache.containsKey(session.connectionId)) return;
    try {
      // Detect login shell and resolve tmux path in a single exec.
      // Redirect stdout from profile scripts to /dev/null so greetings,
      // MOTD, or fortune output don't corrupt our parsed output.
      final execSession = await session.execute(
        r'SHELL_NAME=$(basename "$SHELL" 2>/dev/null || echo sh); '
        r'case "$SHELL_NAME" in '
        'zsh) { . ~/.zprofile; } >/dev/null 2>&1;; '
        'bash) { . ~/.bash_profile; . ~/.profile; } >/dev/null 2>&1;; '
        '*) { . ~/.profile; } >/dev/null 2>&1;; '
        'esac; '
        r'echo "$SHELL_NAME"; '
        'command -v tmux',
      );
      try {
        final results = await Future.wait([
          execSession.stdout.cast<List<int>>().transform(utf8.decoder).join(),
          execSession.stderr.cast<List<int>>().transform(utf8.decoder).join(),
        ]).timeout(const Duration(seconds: 10), onTimeout: () => ['', '']);
        final lines = results[0].trim().split('\n');
        if (lines.isNotEmpty) {
          final shellName = lines[0].trim();
          _profileSourceCache[session.connectionId] = switch (shellName) {
            'zsh' => '{ . ~/.zprofile; } >/dev/null 2>&1; ',
            'bash' => '{ . ~/.bash_profile; . ~/.profile; } >/dev/null 2>&1; ',
            _ => '{ . ~/.profile; } >/dev/null 2>&1; ',
          };
        }
        if (lines.length > 1) {
          final path = lines[1].trim();
          if (path.isNotEmpty && path.startsWith('/')) {
            _tmuxPathCache[session.connectionId] = path;
          }
        }
      } finally {
        execSession.close();
      }
    } on Object {
      // Ignore — we'll fall back to sourcing all profiles.
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

const _tmuxWindowSubscriptionFormat =
    '#{window_index}|#{window_name}|#{window_active}|'
    '#{pane_current_command}|#{pane_current_path}|'
    '#{window_flags}|#{pane_title}|#{window_activity}';

const _tmuxControlModeClientFlags = 'read-only,ignore-size,no-output,wait-exit';

/// Builds the tmux control-mode attach command used for live window updates.
@visibleForTesting
String buildTmuxControlModeAttachCommand(String sessionName) =>
    'tmux -CC attach-session -f $_tmuxControlModeClientFlags '
    '-t ${TmuxService._shellQuote(sessionName)}';

/// Builds the tmux control-mode subscription command for window snapshots.
@visibleForTesting
String buildTmuxWindowSubscriptionCommand(String subscriptionName) =>
    "refresh-client -B '$subscriptionName:@*:$_tmuxWindowSubscriptionFormat'";

/// Returns whether a control-mode output [line] should trigger a window
/// snapshot refresh for the observer using [subscriptionName].
@visibleForTesting
bool shouldReloadTmuxWindowsFromControlLine(
  String line, {
  required String subscriptionName,
}) {
  final trimmed = line.trim();
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith('%subscription-changed $subscriptionName ')) {
    return true;
  }

  const notificationPrefixes = <String>[
    '%session-changed ',
    '%session-renamed ',
    '%session-window-changed ',
    '%sessions-changed',
    '%unlinked-window-add ',
    '%unlinked-window-close ',
    '%unlinked-window-renamed ',
    '%window-add ',
    '%window-close ',
    '%window-pane-changed ',
    '%window-renamed ',
  ];
  return notificationPrefixes.any(trimmed.startsWith);
}

@immutable
class _TmuxWindowWatchKey {
  const _TmuxWindowWatchKey({
    required this.connectionId,
    required this.sessionName,
  });

  final int connectionId;
  final String sessionName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TmuxWindowWatchKey &&
          connectionId == other.connectionId &&
          sessionName == other.sessionName;

  @override
  int get hashCode => Object.hash(connectionId, sessionName);
}

class _TmuxWindowChangeObserver {
  _TmuxWindowChangeObserver({
    required this.service,
    required this.session,
    required this.sessionName,
    required this.onDispose,
  }) : _controller = StreamController<void>.broadcast() {
    _controller
      ..onListen = _ensureStarted
      ..onCancel = () => unawaited(dispose());
  }

  static const _eventDebounce = Duration(milliseconds: 150);

  final TmuxService service;
  final SshSession session;
  final String sessionName;
  final VoidCallback onDispose;
  final StreamController<void> _controller;

  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  StreamSubscription<void>? _doneSubscription;
  Timer? _debounceTimer;
  Timer? _restartTimer;
  SSHSession? _controlSession;
  bool _starting = false;
  bool _disposed = false;
  int _restartAttempts = 0;

  String get _subscriptionName =>
      'flutty-${session.connectionId}-${sessionName.hashCode.abs()}';

  Stream<void> get stream => _controller.stream;

  Future<void> _ensureStarted() async {
    if (_disposed || _starting || _controlSession != null) return;
    _starting = true;
    try {
      await service._cacheTmuxPath(session);
      final execSession = await session.execute(
        service._wrapCommand(
          session,
          buildTmuxControlModeAttachCommand(sessionName),
        ),
      );
      if (_disposed) {
        execSession.close();
        return;
      }

      _controlSession = execSession;
      _stdoutSubscription = execSession.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStdoutLine, onError: _handleControlFailure);
      _stderrSubscription = execSession.stderr
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleStderrLine, onError: _handleControlFailure);
      _doneSubscription = execSession.done.asStream().listen(
        (_) => _handleControlClosed(),
        onError: _handleControlFailure,
      );
      _configureControlSession();
      _restartAttempts = 0;
    } on Object catch (error, stackTrace) {
      _handleControlFailure(error, stackTrace);
    } finally {
      _starting = false;
    }
  }

  void _configureControlSession() {
    final controlSession = _controlSession;
    if (controlSession == null) return;
    controlSession.write(
      utf8.encode('${buildTmuxWindowSubscriptionCommand(_subscriptionName)}\n'),
    );
  }

  void _handleStdoutLine(String line) {
    if (_disposed) return;
    final trimmed = line.trim();
    if (trimmed.startsWith('%exit')) {
      _handleControlClosed();
      return;
    }
    if (!shouldReloadTmuxWindowsFromControlLine(
      trimmed,
      subscriptionName: _subscriptionName,
    )) {
      return;
    }
    _scheduleEvent();
  }

  void _handleStderrLine(String line) {
    if (_disposed || line.trim().isEmpty) return;
    _scheduleRestart();
  }

  void _scheduleEvent() {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_eventDebounce, () {
      if (!_disposed && !_controller.isClosed) {
        _controller.add(null);
      }
    });
  }

  void _handleControlFailure(Object error, StackTrace stackTrace) {
    _scheduleRestart();
  }

  void _handleControlClosed() {
    _cleanupControlSession();
    _scheduleRestart();
  }

  void _scheduleRestart() {
    if (_disposed || !_controller.hasListener) return;
    _restartTimer?.cancel();
    final cappedAttempt = _restartAttempts.clamp(0, 4);
    final delay = Duration(seconds: 1 << cappedAttempt);
    _restartAttempts += 1;
    _restartTimer = Timer(delay, () => unawaited(_ensureStarted()));
  }

  void _cleanupControlSession() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    unawaited(_doneSubscription?.cancel());
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _doneSubscription = null;
    _controlSession?.close();
    _controlSession = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _restartTimer?.cancel();
    _restartTimer = null;
    _cleanupControlSession();
    if (!_controller.isClosed) {
      await _controller.close();
    }
    onDispose();
  }
}

/// Provider for [TmuxService].
final tmuxServiceProvider = Provider<TmuxService>((ref) => const TmuxService());
