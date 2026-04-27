import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/tmux_state.dart';
import 'diagnostics_log_service.dart';
import 'ssh_service.dart';

/// Error thrown when a tmux command channel ends before confirming completion.
class TmuxCommandException implements Exception {
  /// Creates a [TmuxCommandException].
  const TmuxCommandException(this.message);

  /// Human-readable description of the command failure.
  final String message;

  @override
  String toString() => message;
}

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
  const TmuxService({
    Duration execOpenTimeout = const Duration(seconds: 10),
    Duration execOutputTimeout = const Duration(seconds: 10),
  }) : _execOpenTimeout = execOpenTimeout,
       _execOutputTimeout = execOutputTimeout;

  final Duration _execOpenTimeout;
  final Duration _execOutputTimeout;

  /// Cached tmux binary paths per SSH session (by connectionId).
  static final Map<int, String> _tmuxPathCache = {};

  /// Cached profile source commands per SSH session.
  static final Map<int, String> _profileSourceCache = {};

  /// Cached set of installed agent CLIs per SSH session (by connectionId).
  static final _installedAgentToolsCache = <int, _CachedInstalledAgentTools>{};

  static final _installedAgentToolRequests =
      <int, Future<Set<AgentLaunchTool>>>{};

  static final _windowObservers =
      <_TmuxWindowWatchKey, _TmuxWindowChangeObserver>{};
  static final _windowListRequests =
      <_TmuxWindowWatchKey, Future<List<TmuxWindow>>>{};

  static const _execDoneMarker = '__flutty_tmux_exec_done__';
  static const _installedAgentToolsFreshTtl = Duration(minutes: 30);
  static final RegExp _execDoneMarkerLinePattern = RegExp(
    '(?:^|\\n)${RegExp.escape(_execDoneMarker)}:([0-9]+)\\n',
  );

  /// Clears the cached tmux path for a connection.
  void clearCache(int connectionId) {
    DiagnosticsLogService.instance.info(
      'tmux.cache',
      'clear',
      fields: {
        'connectionId': connectionId,
        'observerCount': _windowObservers.keys
            .where((key) => key.connectionId == connectionId)
            .length,
      },
    );
    _tmuxPathCache.remove(connectionId);
    _profileSourceCache.remove(connectionId);
    _installedAgentToolsCache.remove(connectionId);
    _installedAgentToolRequests.remove(connectionId);
    _windowListRequests.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
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
    DiagnosticsLogService.instance.debug(
      'tmux.detect',
      'active_check_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      // Cache the tmux binary path on first successful detection.
      await _cacheTmuxPath(session);
      final output = await _exec(session, 'tmux list-sessions 2>/dev/null');
      final active = output.trim().isNotEmpty;
      DiagnosticsLogService.instance.info(
        'tmux.detect',
        'active_check_complete',
        fields: {'connectionId': session.connectionId, 'active': active},
      );
      return active;
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.detect',
        'active_check_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  /// Returns `true` if tmux is installed on the remote host.
  Future<bool> isTmuxInstalled(SshSession session) async {
    DiagnosticsLogService.instance.debug(
      'tmux.detect',
      'installed_check_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final cachedTmuxPath = _tmuxPathCache[session.connectionId];
      if (cachedTmuxPath != null && cachedTmuxPath.isNotEmpty) {
        DiagnosticsLogService.instance.info(
          'tmux.detect',
          'installed_check_cached',
          fields: {'connectionId': session.connectionId},
        );
        return true;
      }
      final output = await _exec(session, 'which tmux');
      final installed = output.trim().isNotEmpty;
      DiagnosticsLogService.instance.info(
        'tmux.detect',
        'installed_check_complete',
        fields: {'connectionId': session.connectionId, 'installed': installed},
      );
      return installed;
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.detect',
        'installed_check_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  /// Detects which supported coding-agent CLIs are available on the
  /// remote host's `PATH`.
  ///
  /// Resolves binaries via `command -v` inside an interactive instance of
  /// the user's `$SHELL` (`zsh -ic` / `bash -ic` / …). This is necessary
  /// because many users add agent CLIs (Claude, npm-global bins, etc.)
  /// to `PATH` from their interactive rc file (`~/.zshrc`, `~/.bashrc`)
  /// rather than from a login profile, and SSH exec channels otherwise
  /// only see the minimal system `PATH` plus what we source from
  /// `~/.profile` / `~/.bash_profile` / `~/.zprofile`. The detection
  /// command is built per-binary so it also works on POSIX-strict
  /// `/bin/sh` (dash), where `command -v` rejects multiple operands.
  ///
  /// Detection results, including empty sets, are cached per connection.
  /// Stale cached results are returned immediately while a refresh runs in
  /// the background.
  Future<Set<AgentLaunchTool>> detectInstalledAgentTools(
    SshSession session,
  ) async {
    final cached = _installedAgentToolsCache[session.connectionId];
    if (cached != null) {
      final age = DateTime.now().difference(cached.cachedAt);
      DiagnosticsLogService.instance.info(
        'tmux.agent',
        'tool_detection_cached',
        fields: {
          'connectionId': session.connectionId,
          'toolCount': cached.tools.length,
          'ageMs': age.inMilliseconds,
        },
      );
      if (age >= _installedAgentToolsFreshTtl) {
        unawaited(_refreshInstalledAgentTools(session));
      }
      return cached.tools;
    }

    return _refreshInstalledAgentTools(session);
  }

  /// Warms the installed agent CLI cache in the background.
  Future<void> prefetchInstalledAgentTools(SshSession session) async {
    final cached = _installedAgentToolsCache[session.connectionId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) <
            _installedAgentToolsFreshTtl) {
      return;
    }
    try {
      await _refreshInstalledAgentTools(session);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'tmux.agent',
        'tool_detection_prefetch_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  Future<Set<AgentLaunchTool>> _refreshInstalledAgentTools(SshSession session) {
    final existingRequest = _installedAgentToolRequests[session.connectionId];
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.agent',
        'tool_detection_join',
        fields: {'connectionId': session.connectionId},
      );
      return existingRequest;
    }

    DiagnosticsLogService.instance.info(
      'tmux.agent',
      'tool_detection_start',
      fields: {'connectionId': session.connectionId},
    );
    final request = () async {
      final output = await _exec(session, buildAgentToolDetectionCommand());
      final installed = parseInstalledAgentTools(output);
      _installedAgentToolsCache[session.connectionId] =
          _CachedInstalledAgentTools(
            tools: Set<AgentLaunchTool>.unmodifiable(installed),
            cachedAt: DateTime.now(),
          );
      DiagnosticsLogService.instance.info(
        'tmux.agent',
        'tool_detection_complete',
        fields: {
          'connectionId': session.connectionId,
          'toolCount': installed.length,
        },
      );
      return installed;
    }();
    _installedAgentToolRequests[session.connectionId] = request;
    request.whenComplete(() {
      if (identical(
        _installedAgentToolRequests[session.connectionId],
        request,
      )) {
        _installedAgentToolRequests.remove(session.connectionId);
      }
    }).ignore();
    return request;
  }

  /// Lists all tmux sessions on the remote host.
  Future<List<TmuxSession>> listSessions(SshSession session) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'list_sessions_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final output = await _exec(
        session,
        'tmux list-sessions -F '
        "'#{session_name}|#{session_windows}|"
        "#{session_attached}|#{session_activity}'",
      );
      final sessions = _parseLines(output, TmuxSession.fromTmuxFormat);
      DiagnosticsLogService.instance.info(
        'tmux.query',
        'list_sessions_complete',
        fields: {
          'connectionId': session.connectionId,
          'sessionCount': sessions.length,
        },
      );
      return sessions;
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'list_sessions_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
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
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'current_session_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      // Direct approach — works if the exec channel is inside tmux.
      final output = await _exec(
        session,
        "tmux display-message -p '#{session_name}'",
      );
      final name = output.trim();
      if (name.isNotEmpty) {
        DiagnosticsLogService.instance.info(
          'tmux.query',
          'current_session_direct',
          fields: {'connectionId': session.connectionId},
        );
        return name;
      }
    } on Exception catch (error) {
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'current_session_direct_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      // Fall through to fallback.
    }

    // Fallback — find attached sessions.
    try {
      final sessions = await listSessions(session);
      final attached = sessions.where((s) => s.isAttached).toList();
      if (attached.length == 1) {
        DiagnosticsLogService.instance.info(
          'tmux.query',
          'current_session_attached_fallback',
          fields: {'connectionId': session.connectionId},
        );
        return attached.first.name;
      }
      // Multiple attached sessions are ambiguous — we can't determine
      // which one belongs to this terminal connection. Return null to
      // avoid targeting the wrong session with destructive operations.
      DiagnosticsLogService.instance.info(
        'tmux.query',
        'current_session_ambiguous',
        fields: {
          'connectionId': session.connectionId,
          'attachedCount': attached.length,
        },
      );
      return null;
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'current_session_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Returns `true` if [sessionName] exists on the remote tmux server.
  Future<bool> hasSession(SshSession session, String sessionName) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'has_session_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      await _cacheTmuxPath(session);
      final output = await _exec(
        session,
        'tmux has-session -t ${_shellQuote(sessionName)} 2>/dev/null && printf 1',
      );
      final exists = output.trim() == '1';
      DiagnosticsLogService.instance.info(
        'tmux.query',
        'has_session_complete',
        fields: {'connectionId': session.connectionId, 'exists': exists},
      );
      return exists;
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'has_session_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  // ── Window queries ─────────────────────────────────────────────────────

  /// Lists all windows in the given tmux [sessionName].
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName,
  ) async {
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
    );
    final existingRequest = _windowListRequests[key];
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'list_windows_join',
        fields: {
          'connectionId': session.connectionId,
          'sessionHash': sessionName.hashCode.abs(),
        },
      );
      return existingRequest;
    }

    final request = _listWindows(session, sessionName);
    _windowListRequests[key] = request;
    request.whenComplete(() {
      if (identical(_windowListRequests[key], request)) {
        _windowListRequests.remove(key);
      }
    }).ignore();
    return request;
  }

  Future<List<TmuxWindow>> _listWindows(
    SshSession session,
    String sessionName,
  ) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'list_windows_start',
      fields: {'connectionId': session.connectionId},
    );
    final quotedName = _shellQuote(sessionName);
    const sep = r'${SEP}';
    final output = await _exec(
      session,
      r'SEP=$(printf "\037"); '
      'tmux -u list-windows -t $quotedName -F '
      '"#{window_index}$sep#{window_name}$sep#{window_active}$sep'
      '#{pane_current_command}$sep#{pane_current_path}$sep'
      '#{window_flags}$sep#{pane_title}$sep#{window_activity}$sep'
      '#{pane_start_command}$sep#{@flutty_agent_tool}"',
    );
    final windows = List<TmuxWindow>.unmodifiable(
      _parseLines(output, TmuxWindow.fromTmuxFormat),
    );
    DiagnosticsLogService.instance.info(
      'tmux.query',
      'list_windows_complete',
      fields: {
        'connectionId': session.connectionId,
        'windowCount': windows.length,
        'activeWindowCount': windows.where((window) => window.isActive).length,
        'alertWindowCount': windows.where((window) => window.hasAlert).length,
      },
    );
    return windows;
  }

  /// Returns the active pane working directory for [sessionName], if tmux
  /// reports one.
  Future<String?> currentPanePath(
    SshSession session,
    String sessionName,
  ) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'current_pane_path_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final output = await _exec(
        session,
        'tmux display-message -p -t ${_shellQuote('$sessionName:')} '
        "'#{pane_current_path}'",
      );
      final path = parseTmuxCurrentPanePath(output);
      DiagnosticsLogService.instance.info(
        'tmux.query',
        'current_pane_path_complete',
        fields: {'connectionId': session.connectionId, 'hasPath': path != null},
      );
      return path;
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'current_pane_path_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Returns whether [sessionName] still has a non-control tmux client
  /// attached in the foreground.
  ///
  /// Control-mode observers are excluded because MonkeySSH uses one for live
  /// window updates even after the visible interactive shell has left tmux.
  Future<bool> hasForegroundClient(
    SshSession session,
    String sessionName,
  ) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'foreground_client_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final output = await _exec(
        session,
        'tmux list-clients -t ${_shellQuote(sessionName)} '
        "-F '#{client_control_mode}' 2>/dev/null",
      );
      final hasClient = hasForegroundTmuxClient(output);
      DiagnosticsLogService.instance.info(
        'tmux.query',
        'foreground_client_complete',
        fields: {
          'connectionId': session.connectionId,
          'hasForegroundClient': hasClient,
        },
      );
      return hasClient;
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'foreground_client_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  /// Watches tmux control-mode notifications that indicate window state
  /// has changed for [sessionName].
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName,
  ) {
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
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'watch_requested',
      fields: {
        'connectionId': session.connectionId,
        'observerCount': _windowObservers.length,
      },
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
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'create_window_start',
      fields: {
        'connectionId': session.connectionId,
        'hasCommand': command?.trim().isNotEmpty ?? false,
        'hasName': name?.trim().isNotEmpty ?? false,
        'hasWorkingDirectory': workingDirectory?.trim().isNotEmpty ?? false,
      },
    );
    // Don't pass -c unless an explicit workingDirectory was provided
    // (e.g. resuming an AI session in a specific project). Without -c,
    // tmux uses the session's default-directory — matching Ctrl+b,c.
    final parts = <String>[
      "tmux new-window -P -F '#{window_index}' -t ${_shellQuote(sessionName)}",
      if (workingDirectory != null && workingDirectory.trim().isNotEmpty)
        '-c ${_shellQuote(workingDirectory.trim())}',
      if (name != null && name.trim().isNotEmpty)
        '-n ${_shellQuote(name.trim())}',
    ];
    final createdWindowIndex = _parseCreatedWindowIndex(
      await _exec(session, parts.join(' ')),
    );
    final target = createdWindowIndex == null
        ? sessionName
        : '$sessionName:$createdWindowIndex';
    final agentTool = _agentToolForCreatedWindow(command: command, name: name);
    if (agentTool != null) {
      await _exec(
        session,
        'tmux set-option -w -t ${_shellQuote(target)} '
        '@flutty_agent_tool ${_shellQuote(agentTool.commandName)}',
      );
    }
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'create_window_complete',
      fields: {
        'connectionId': session.connectionId,
        'hasAgentTool': agentTool != null,
      },
    );

    // If a command was requested, type it into the new window's shell.
    // This ensures the command runs inside the login shell environment
    // where CLI tools installed via Homebrew/nvm/etc. are available.
    if (command != null && command.trim().isNotEmpty) {
      _execFireAndForget(
        session,
        'tmux send-keys -t ${_shellQuote(target)} '
        '${_shellQuote(command.trim())} Enter',
      );
      DiagnosticsLogService.instance.info(
        'tmux.action',
        'create_window_command_sent',
        fields: {'connectionId': session.connectionId},
      );
    }
  }

  /// Switches to window [windowIndex] in [sessionName] via exec channel.
  ///
  /// This is a tmux server operation — the server notifies all attached
  /// clients of the change, so it works correctly regardless of which
  /// channel sends the command.
  ///
  /// Waits for tmux to process the selection before returning so callers can
  /// safely perform follow-up work (like reattaching the visible PTY) without
  /// racing the server-side window change.
  Future<void> selectWindow(
    SshSession session,
    String sessionName,
    int windowIndex,
  ) async {
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'select_window_start',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
      },
    );
    await _exec(
      session,
      'tmux select-window -t ${_shellQuote(sessionName)}:$windowIndex',
    );
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'select_window_complete',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
      },
    );
  }

  /// Closes a window in [sessionName] via exec channel.
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex,
  ) async {
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'kill_window_start',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
      },
    );
    await _exec(
      session,
      'tmux kill-window -t ${_shellQuote(sessionName)}:$windowIndex',
    );
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'kill_window_complete',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
      },
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

  /// Opens an SSH exec channel with a bounded wait for channel creation.
  Future<SSHSession> _openExec(
    SshSession session,
    String command, {
    SSHPtyConfig? pty,
  }) {
    DiagnosticsLogService.instance.debug(
      'tmux.exec',
      'open_start',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': _diagnosticTmuxCommandKind(command),
        'pty': pty != null,
      },
    );
    final openFuture = session.execute(command, pty: pty);
    return openFuture.timeout(
      _execOpenTimeout,
      onTimeout: () {
        DiagnosticsLogService.instance.warning(
          'tmux.exec',
          'open_timeout',
          fields: {
            'connectionId': session.connectionId,
            'commandKind': _diagnosticTmuxCommandKind(command),
            'timeoutMs': _execOpenTimeout.inMilliseconds,
            'pty': pty != null,
          },
        );
        openFuture.then((exec) => exec.close()).ignore();
        throw TimeoutException(
          'Timed out opening SSH exec channel',
          _execOpenTimeout,
        );
      },
    );
  }

  /// Runs a command via SSH exec channel and returns stdout as a string.
  ///
  /// Uses the cached tmux binary path when available; otherwise sources
  /// the user's login shell profile to resolve the PATH.
  ///
  /// Appends a marker to the remote command and reads stdout only until that
  /// marker arrives. Some SSH servers leave exec streams open after the
  /// command exits, so waiting for stream completion can turn successful tmux
  /// actions into apparent hangs.
  Future<String> _exec(SshSession session, String command) async {
    final startedAt = DateTime.now();
    final wrappedCommand = _wrapCommand(session, command);
    final execSession = await _openExec(
      session,
      _markCommandDone(wrappedCommand),
    );
    try {
      execSession.stderr.drain<void>().ignore();
      final output = await _readStdoutUntilDoneMarker(
        execSession,
        connectionId: session.connectionId,
        commandKind: _diagnosticTmuxCommandKind(command),
      );
      DiagnosticsLogService.instance.debug(
        'tmux.exec',
        'complete',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': _diagnosticTmuxCommandKind(command),
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
          'outputChars': output.length,
        },
      );
      return output;
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.exec',
        'failed',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': _diagnosticTmuxCommandKind(command),
          'durationMs': DateTime.now().difference(startedAt).inMilliseconds,
          'errorType': error.runtimeType,
        },
      );
      rethrow;
    } finally {
      execSession.close();
    }
  }

  String _markCommandDone(String command) =>
      '{ $command; __flutty_tmux_exec_status__=\$?; '
      'printf ${_shellQuote('\n$_execDoneMarker:%s\n')} '
      r'"$__flutty_tmux_exec_status__"; }';

  Future<String> _readStdoutUntilDoneMarker(
    SSHSession execSession, {
    required int connectionId,
    required String commandKind,
  }) async {
    final output = StringBuffer();
    await for (final chunk
        in execSession.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .timeout(_execOutputTimeout)) {
      DiagnosticsLogService.instance.debug(
        'tmux.exec',
        'stdout_chunk',
        fields: {
          'connectionId': connectionId,
          'commandKind': commandKind,
          'charCount': chunk.length,
        },
      );
      output.write(chunk);
      final currentOutput = output.toString();
      RegExpMatch? markerMatch;
      for (final match in _execDoneMarkerLinePattern.allMatches(
        currentOutput,
      )) {
        markerMatch = match;
      }
      if (markerMatch != null) {
        final statusText = markerMatch.group(1)!;
        final exitStatus = int.parse(statusText);
        if (exitStatus != 0) {
          DiagnosticsLogService.instance.warning(
            'tmux.exec',
            'nonzero_status',
            fields: {
              'connectionId': connectionId,
              'commandKind': commandKind,
              'exitStatus': exitStatus,
            },
          );
          throw TmuxCommandException(
            'tmux command failed with exit status $statusText',
          );
        }
        return currentOutput.substring(0, markerMatch.start).trimRight();
      }
    }
    DiagnosticsLogService.instance.warning(
      'tmux.exec',
      'closed_before_marker',
      fields: {'connectionId': connectionId, 'commandKind': commandKind},
    );
    throw const TmuxCommandException(
      'SSH exec channel closed before tmux command completed',
    );
  }

  /// Fire-and-forget: sends a tmux command without waiting for output.
  ///
  /// Used for operations like `select-window` where the result is
  /// visible immediately in the interactive terminal. Avoids the
  /// latency of draining stdout/stderr.
  void _execFireAndForget(SshSession session, String command) {
    final wrappedCommand = _wrapCommand(session, command);
    DiagnosticsLogService.instance.debug(
      'tmux.exec',
      'fire_and_forget_start',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': _diagnosticTmuxCommandKind(command),
      },
    );
    // Launch and ignore — the exec channel self-closes on completion.
    _openExec(session, wrappedCommand)
        .then((exec) {
          // Drain streams to prevent backpressure, but don't wait.
          exec.stdout.drain<void>().ignore();
          exec.stderr.drain<void>().ignore();
        })
        .catchError((Object error) {
          DiagnosticsLogService.instance.warning(
            'tmux.exec',
            'fire_and_forget_failed',
            fields: {
              'connectionId': session.connectionId,
              'commandKind': _diagnosticTmuxCommandKind(command),
              'errorType': error.runtimeType,
            },
          );
        })
        .ignore();
  }

  /// Detects the user's login shell and resolves the tmux binary path.
  ///
  /// Caches both the shell-specific profile source command and the
  /// full tmux path for subsequent calls.
  Future<void> _cacheTmuxPath(SshSession session) async {
    if (_tmuxPathCache.containsKey(session.connectionId)) return;
    DiagnosticsLogService.instance.debug(
      'tmux.cache',
      'tmux_path_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      // Detect login shell and resolve tmux path in a single exec.
      // Redirect stdout from profile scripts to /dev/null so greetings,
      // MOTD, or fortune output don't corrupt our parsed output.
      final output = await _exec(
        session,
        r'SHELL_NAME=$(basename "$SHELL" 2>/dev/null || echo sh); '
        r'case "$SHELL_NAME" in '
        'zsh) { . ~/.zprofile; } >/dev/null 2>&1;; '
        'bash) { . ~/.bash_profile; . ~/.profile; } >/dev/null 2>&1;; '
        '*) { . ~/.profile; } >/dev/null 2>&1;; '
        'esac; '
        r'echo "$SHELL_NAME"; '
        'command -v tmux',
      );
      final lines = output.trim().split('\n');
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
      DiagnosticsLogService.instance.info(
        'tmux.cache',
        'tmux_path_complete',
        fields: {
          'connectionId': session.connectionId,
          'hasPath': _tmuxPathCache.containsKey(session.connectionId),
          'hasProfile': _profileSourceCache.containsKey(session.connectionId),
        },
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.cache',
        'tmux_path_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
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

int? _parseCreatedWindowIndex(String output) {
  for (final rawLine in output.split('\n')) {
    final index = int.tryParse(rawLine.trim());
    if (index != null) return index;
  }
  return null;
}

AgentLaunchTool? _agentToolForCreatedWindow({
  required String? command,
  required String? name,
}) =>
    agentLaunchToolForCommandName(name) ??
    agentLaunchToolForCommandText(command);

class _CachedInstalledAgentTools {
  const _CachedInstalledAgentTools({
    required this.tools,
    required this.cachedAt,
  });

  final Set<AgentLaunchTool> tools;
  final DateTime cachedAt;
}

String _diagnosticTmuxCommandKind(String command) {
  if (command.contains('attach-session')) {
    return 'control_attach';
  }
  if (command.contains('refresh-client')) {
    return 'control_subscription';
  }
  if (command.contains('list-windows')) {
    return 'list_windows';
  }
  if (command.contains('list-sessions')) {
    return 'list_sessions';
  }
  if (command.contains('display-message')) {
    return 'display_message';
  }
  if (command.contains('has-session')) {
    return 'has_session';
  }
  if (command.contains('list-clients')) {
    return 'list_clients';
  }
  if (command.contains('select-window')) {
    return 'select_window';
  }
  if (command.contains('new-window')) {
    return 'new_window';
  }
  if (command.contains('kill-window')) {
    return 'kill_window';
  }
  if (command.contains('send-keys')) {
    return 'send_keys';
  }
  if (command.contains('command -v')) {
    return 'tool_detection';
  }
  if (command.contains('which tmux')) {
    return 'which_tmux';
  }
  return 'tmux_exec';
}

/// Parses the current pane path reported by `tmux display-message`.
@visibleForTesting
String? parseTmuxCurrentPanePath(String output) {
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (line.isNotEmpty) {
      return line;
    }
  }
  return null;
}

/// Returns whether `tmux list-clients` output includes a non-control client.
@visibleForTesting
bool hasForegroundTmuxClient(String output) {
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (line == '0') {
      return true;
    }
  }
  return false;
}

const _tmuxWindowSubscriptionFormat =
    '#{window_index}$tmuxWindowFieldSeparator'
    '#{window_name}$tmuxWindowFieldSeparator'
    '#{window_active}$tmuxWindowFieldSeparator'
    '#{pane_current_command}$tmuxWindowFieldSeparator'
    '#{pane_current_path}$tmuxWindowFieldSeparator'
    '#{window_flags}$tmuxWindowFieldSeparator'
    '#{pane_title}$tmuxWindowFieldSeparator'
    '#{window_activity}$tmuxWindowFieldSeparator'
    '#{pane_start_command}$tmuxWindowFieldSeparator'
    '#{@flutty_agent_tool}';

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

String _normalizeTmuxControlLine(String line) {
  var normalized = line.trim();
  normalized = normalized.replaceFirst(RegExp(r'^\u001bP\d+p'), '');
  normalized = normalized.replaceFirst(RegExp(r'\u001b\\$'), '');
  return normalized.trim();
}

/// Returns a safe category for a tmux control-mode line without exposing the
/// raw line contents.
@visibleForTesting
String diagnosticTmuxControlLineKind(String line) {
  final trimmed = _normalizeTmuxControlLine(line);
  if (trimmed.isEmpty) return 'empty';
  final separator = trimmed.indexOf(' ');
  final marker = separator == -1 ? trimmed : trimmed.substring(0, separator);
  if (marker.startsWith('%')) {
    return marker.substring(1).replaceAll('-', '_');
  }
  return 'other';
}

/// Returns whether [line] should trigger a debounced reload fallback when a
/// direct snapshot either does not arrive or cannot be parsed.
///
/// tmux normally follows window-change notifications like
/// `%session-window-changed` with `%subscription-changed` snapshots, but some
/// hosts intermittently stop delivering the snapshot while still emitting the
/// lifecycle notification. Treat those lines as a fallback reload trigger so
/// the UI does not get stuck on stale window metadata.
@visibleForTesting
bool shouldScheduleTmuxWindowReloadFallback(
  String line, {
  required String subscriptionName,
}) {
  final trimmed = _normalizeTmuxControlLine(line);
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith('%subscription-changed $subscriptionName ')) {
    return true;
  }

  const notificationPrefixes = <String>[
    '%pane-mode-changed ',
    '%session-window-changed ',
    '%sessions-changed',
    '%unlinked-window-add ',
    '%unlinked-window-close ',
    '%unlinked-window-renamed ',
    '%window-add ',
    '%window-close ',
    '%window-renamed ',
  ];
  return notificationPrefixes.any(trimmed.startsWith);
}

/// Returns whether a scheduled tmux reload should be preserved even if a later
/// snapshot arrives before the debounce fires.
///
/// Window add/remove lifecycle events need a full `list-windows` refresh so the
/// local list can drop removed windows and pick up newly created ones. A later
/// per-window snapshot is not enough to reconcile those structural changes.
@visibleForTesting
bool shouldPreserveTmuxWindowReloadThroughSnapshots(String line) {
  final trimmed = _normalizeTmuxControlLine(line);
  const notificationPrefixes = <String>[
    '%sessions-changed',
    '%unlinked-window-add ',
    '%unlinked-window-close ',
    '%window-add ',
    '%window-close ',
  ];
  return notificationPrefixes.any(trimmed.startsWith);
}

/// Parses a control-mode output [line] into a tmux window change event for
/// the observer using [subscriptionName].
@visibleForTesting
TmuxWindowChangeEvent? parseTmuxWindowChangeEventFromControlLine(
  String line, {
  required String subscriptionName,
}) {
  final trimmed = _normalizeTmuxControlLine(line);
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('%subscription-changed $subscriptionName ')) {
    final valueSeparator = trimmed.indexOf(' : ');
    if (valueSeparator == -1 || valueSeparator + 3 >= trimmed.length) {
      return const TmuxWindowReloadEvent();
    }
    final value = trimmed.substring(valueSeparator + 3);
    try {
      return TmuxWindowSnapshotEvent(TmuxWindow.fromTmuxFormat(value));
    } on FormatException {
      return const TmuxWindowReloadEvent();
    }
  }

  const notificationPrefixes = <String>[
    '%pane-mode-changed ',
    '%sessions-changed',
    '%unlinked-window-add ',
    '%unlinked-window-close ',
    '%unlinked-window-renamed ',
    '%window-add ',
    '%window-close ',
  ];
  if (notificationPrefixes.any(trimmed.startsWith)) {
    return const TmuxWindowReloadEvent();
  }
  return null;
}

/// Action the tmux control-mode heartbeat decides to take based on how long
/// the channel has been silent.
@visibleForTesting
enum TmuxControlHeartbeatAction {
  /// No action — control-mode notifications have arrived recently.
  noop,

  /// Synthesize a refresh event so listeners refetch window state.
  refresh,
}

/// Pure decision function used by the control-mode observer's heartbeat
/// to keep the UI in sync when push notifications are dropped or the SSH
/// channel is quiet.
@visibleForTesting
TmuxControlHeartbeatAction decideTmuxHeartbeatAction({
  required Duration silence,
  required Duration heartbeatInterval,
}) {
  if (silence >= heartbeatInterval) {
    return TmuxControlHeartbeatAction.refresh;
  }
  return TmuxControlHeartbeatAction.noop;
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
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _controller = StreamController<TmuxWindowChangeEvent>.broadcast() {
    _controller
      ..onListen = _ensureStarted
      ..onCancel = () => unawaited(dispose());
  }

  static const _eventDebounce = Duration(milliseconds: 150);

  /// How often to check whether the control-mode session has gone quiet and
  /// synthesize a refresh event when it has. Keeps the UI in sync even if
  /// `%subscription-changed` notifications are dropped.
  static const _heartbeatInterval = Duration(seconds: 5);

  final TmuxService service;
  final SshSession session;
  final String sessionName;
  final VoidCallback onDispose;
  final DateTime Function() _now;
  final StreamController<TmuxWindowChangeEvent> _controller;

  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  StreamSubscription<void>? _doneSubscription;
  Timer? _debounceTimer;
  Timer? _restartTimer;
  Timer? _heartbeatTimer;
  SSHSession? _controlSession;
  bool _starting = false;
  bool _disposed = false;
  bool _preserveScheduledReloadThroughSnapshots = false;
  int _restartAttempts = 0;
  DateTime? _lastControlActivity;

  String get _subscriptionName =>
      'flutty-${session.connectionId}-${sessionName.hashCode.abs()}';

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  Future<void> _ensureStarted() async {
    if (_disposed || _starting || _controlSession != null) return;
    _starting = true;
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'start',
      fields: {
        'connectionId': session.connectionId,
        'restartAttempts': _restartAttempts,
      },
    );
    try {
      await service._cacheTmuxPath(session);
      final execSession = await service._openExec(
        session,
        service._wrapCommand(
          session,
          buildTmuxControlModeAttachCommand(sessionName),
        ),
        // tmux control mode stays silent over a plain exec channel on some SSH
        // servers. Request a dedicated PTY so `%subscription-changed` events
        // stream in real time instead of only catching up on fallback reloads.
        pty: const SSHPtyConfig(),
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
      _lastControlActivity = _now();
      _startHeartbeat();
      DiagnosticsLogService.instance.info(
        'tmux.watch',
        'started',
        fields: {'connectionId': session.connectionId},
      );
    } on Object catch (error, stackTrace) {
      _handleControlFailure(error, stackTrace);
    } finally {
      _starting = false;
    }
  }

  void _configureControlSession() {
    final controlSession = _controlSession;
    if (controlSession == null) return;
    DiagnosticsLogService.instance.debug(
      'tmux.watch',
      'subscribe',
      fields: {'connectionId': session.connectionId},
    );
    controlSession.write(
      utf8.encode('${buildTmuxWindowSubscriptionCommand(_subscriptionName)}\n'),
    );
  }

  void _handleStdoutLine(String line) {
    if (_disposed) return;
    _lastControlActivity = _now();
    final trimmed = _normalizeTmuxControlLine(line);
    if (trimmed.startsWith('%exit')) {
      DiagnosticsLogService.instance.info(
        'tmux.watch',
        'control_exit',
        fields: {'connectionId': session.connectionId},
      );
      _handleControlClosed();
      return;
    }
    final event = parseTmuxWindowChangeEventFromControlLine(
      trimmed,
      subscriptionName: _subscriptionName,
    );
    if (event == null) {
      if (shouldScheduleTmuxWindowReloadFallback(
        trimmed,
        subscriptionName: _subscriptionName,
      )) {
        DiagnosticsLogService.instance.debug(
          'tmux.watch',
          'fallback_reload_signal',
          fields: {
            'connectionId': session.connectionId,
            'lineKind': diagnosticTmuxControlLineKind(trimmed),
          },
        );
        _scheduleReloadEvent(
          preserveThroughSnapshots:
              shouldPreserveTmuxWindowReloadThroughSnapshots(trimmed),
        );
      }
      return;
    }
    if (event is TmuxWindowSnapshotEvent) {
      if (!_preserveScheduledReloadThroughSnapshots) {
        _cancelScheduledReload();
      }
      DiagnosticsLogService.instance.debug(
        'tmux.watch',
        'snapshot_event',
        fields: {'connectionId': session.connectionId},
      );
      _emitEvent(event);
      return;
    }
    DiagnosticsLogService.instance.debug(
      'tmux.watch',
      'reload_event',
      fields: {
        'connectionId': session.connectionId,
        'lineKind': diagnosticTmuxControlLineKind(trimmed),
      },
    );
    _scheduleReloadEvent(
      preserveThroughSnapshots: shouldPreserveTmuxWindowReloadThroughSnapshots(
        trimmed,
      ),
    );
  }

  void _handleStderrLine(String line) {
    if (_disposed || line.trim().isEmpty) return;
    _lastControlActivity = _now();
    DiagnosticsLogService.instance.warning(
      'tmux.watch',
      'stderr_line',
      fields: {'connectionId': session.connectionId, 'charCount': line.length},
    );
    _scheduleRestart();
  }

  void _emitEvent(TmuxWindowChangeEvent event) {
    if (_disposed || _controller.isClosed) return;
    _controller.add(event);
  }

  void _cancelScheduledReload() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _preserveScheduledReloadThroughSnapshots = false;
  }

  void _scheduleReloadEvent({bool preserveThroughSnapshots = false}) {
    if (_disposed) return;
    _debounceTimer?.cancel();
    _preserveScheduledReloadThroughSnapshots =
        _preserveScheduledReloadThroughSnapshots || preserveThroughSnapshots;
    _debounceTimer = Timer(_eventDebounce, () {
      _debounceTimer = null;
      _preserveScheduledReloadThroughSnapshots = false;
      if (!_disposed && !_controller.isClosed) {
        DiagnosticsLogService.instance.debug(
          'tmux.watch',
          'emit_scheduled_reload',
          fields: {'connectionId': session.connectionId},
        );
        _controller.add(const TmuxWindowReloadEvent());
      }
    });
  }

  void _handleControlFailure(Object error, StackTrace stackTrace) {
    DiagnosticsLogService.instance.warning(
      'tmux.watch',
      'control_failure',
      fields: {
        'connectionId': session.connectionId,
        'errorType': error.runtimeType,
      },
    );
    _scheduleRestart();
  }

  void _handleControlClosed() {
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'control_closed',
      fields: {'connectionId': session.connectionId},
    );
    _cleanupControlSession();
    _scheduleRestart();
  }

  void _scheduleRestart() {
    if (_disposed || !_controller.hasListener) return;
    _stopHeartbeat();
    _restartTimer?.cancel();
    final cappedAttempt = _restartAttempts.clamp(0, 4);
    final delay = Duration(seconds: 1 << cappedAttempt);
    _restartAttempts += 1;
    DiagnosticsLogService.instance.warning(
      'tmux.watch',
      'restart_scheduled',
      fields: {
        'connectionId': session.connectionId,
        'attempt': _restartAttempts,
        'delayMs': delay.inMilliseconds,
      },
    );
    _restartTimer = Timer(delay, () => unawaited(_ensureStarted()));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) => _onHeartbeat());
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  /// Heartbeat tick:
  ///
  /// If the control session has been quiet for [_heartbeatInterval],
  /// synthesize a refresh event so listeners refetch window state. Do not
  /// restart a quiet control session; tmux can legitimately stay silent after
  /// its initial subscription snapshot, and frequent restarts consume SSH
  /// session channels on servers with low `MaxSessions` limits.
  void _onHeartbeat() {
    if (_disposed) return;
    final lastActivity = _lastControlActivity;
    if (lastActivity == null) return;
    final action = decideTmuxHeartbeatAction(
      silence: _now().difference(lastActivity),
      heartbeatInterval: _heartbeatInterval,
    );
    switch (action) {
      case TmuxControlHeartbeatAction.noop:
        return;
      case TmuxControlHeartbeatAction.refresh:
        DiagnosticsLogService.instance.debug(
          'tmux.watch',
          'heartbeat_refresh',
          fields: {
            'connectionId': session.connectionId,
            'silenceMs': _now().difference(lastActivity).inMilliseconds,
          },
        );
        _scheduleReloadEvent();
        return;
    }
  }

  void _cleanupControlSession() {
    _stopHeartbeat();
    _cancelScheduledReload();
    unawaited(_stdoutSubscription?.cancel());
    unawaited(_stderrSubscription?.cancel());
    unawaited(_doneSubscription?.cancel());
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _doneSubscription = null;
    _controlSession?.close();
    _controlSession = null;
    _lastControlActivity = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'dispose',
      fields: {'connectionId': session.connectionId},
    );
    _disposed = true;
    _stopHeartbeat();
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

/// Maps a binary's basename (e.g. `claude`) to the matching [AgentLaunchTool],
/// or `null` if it does not correspond to a supported CLI.
AgentLaunchTool? agentToolForBinaryName(String binaryName) =>
    agentLaunchToolForCommandName(binaryName);

/// Builds the shell command used by [TmuxService.detectInstalledAgentTools]
/// to resolve agent CLI binaries on a remote host.
///
/// The command:
///
/// - Loops one binary at a time so it works on POSIX-strict shells like
///   `dash`, where `command -v a b c` rejects the extra operands and
///   prints nothing.
/// - Re-invokes the user's interactive `$SHELL` (`zsh -ic`, `bash -ic`,
///   …) so PATH additions made from `~/.zshrc` / `~/.bashrc` (where
///   tools like `claude` and other npm-global / asdf / mise / pyenv
///   installs are commonly added) are picked up. Login-only profile
///   sourcing — what SSH exec channels otherwise see — misses these.
/// - Falls back to `/bin/sh` if `$SHELL` is unset, and tolerates the
///   inner `command -v` exiting non-zero when a binary is missing.
@visibleForTesting
String buildAgentToolDetectionCommand() {
  final binaries =
      AgentLaunchTool.values.map((t) => t.commandName).toSet().toList()..sort();
  final inner =
      'for c in ${binaries.join(' ')}; do '
      r'command -v "$c" 2>/dev/null; '
      'done';
  // Single-quote the inner snippet for the outer shell, then escape any
  // single quotes inside it. There are none today, but this keeps the
  // builder safe if someone adds a binary name containing a quote.
  final quotedInner = "'${inner.replaceAll("'", "'\"'\"'")}'";
  return r'SH="${SHELL:-/bin/sh}"; "$SH" -ic '
      '$quotedInner '
      '2>/dev/null || true';
}

/// agent CLIs that resolved to an absolute path.
///
/// Lines that do not start with `/` are ignored, so shell function names,
/// builtins, or aliases (which `command -v` may report as bare names) are
/// not treated as installed CLIs.
Set<AgentLaunchTool> parseInstalledAgentTools(String output) {
  final installed = <AgentLaunchTool>{};
  for (final rawLine in output.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || !line.startsWith('/')) continue;
    final binary = line.split('/').last;
    final tool = agentToolForBinaryName(binary);
    if (tool != null) installed.add(tool);
  }
  return installed;
}
