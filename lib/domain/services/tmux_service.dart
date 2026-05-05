import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/terminal_theme.dart';
import '../models/tmux_state.dart';
import 'diagnostics_log_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';

const _backslashCodeUnit = 0x5C;

enum _ShellQuoteMode { none, single, double }

class _ShellToken {
  const _ShellToken({required this.value, required this.raw});

  final String value;
  final String raw;
}

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

  /// In-flight tmux path/profile probes per SSH session.
  static final Map<int, Future<void>> _tmuxPathRequests = {};

  /// In-flight tmux session-existence probes.
  static final _hasSessionRequests = <_TmuxSessionRequestKey, Future<bool>>{};

  /// Cached set of installed agent CLIs per SSH session (by connectionId).
  static final _installedAgentToolsCache = <int, _CachedInstalledAgentTools>{};

  static final _installedAgentToolRequests =
      <int, Future<Set<AgentLaunchTool>>>{};

  static final _windowObservers =
      <_TmuxWindowWatchKey, _TmuxWindowChangeObserver>{};
  static final _windowListRequests =
      <_TmuxWindowWatchKey, Future<List<TmuxWindow>>>{};
  static final _windowSnapshotCache = <_TmuxWindowWatchKey, List<TmuxWindow>>{};
  static final _execChannelBackoffs = <int, _TmuxExecChannelBackoff>{};

  static const _execDoneMarker = '__flutty_tmux_exec_done__';
  static const _installedAgentToolsFreshTtl = Duration(minutes: 30);
  static final RegExp _execDoneMarkerLinePattern = RegExp(
    '(?:^|\\n)${RegExp.escape(_execDoneMarker)}:([0-9]+)\\n',
  );

  static String _tmuxCommand(
    String command, {
    String? extraFlags,
    bool forceUtf8 = false,
  }) {
    final clientFlags = resolveTmuxClientFlagsFromExtraFlags(extraFlags);
    final options = <String>[if (forceUtf8) '-u', ?clientFlags];
    final optionText = options.isEmpty ? '' : '${options.join(' ')} ';
    return 'tmux $optionText$command';
  }

  /// Returns whether a tmux binary path cache entry exists for [connectionId].
  @visibleForTesting
  static bool hasTmuxPathCacheEntry(int connectionId) =>
      _tmuxPathCache.containsKey(connectionId);

  /// Returns whether an installed agent tools cache entry exists for
  /// [connectionId].
  @visibleForTesting
  static bool hasInstalledAgentToolsCacheEntry(int connectionId) =>
      _installedAgentToolsCache.containsKey(connectionId);

  /// Returns whether a window snapshot cache entry exists for [connectionId].
  @visibleForTesting
  static bool hasWindowSnapshotCacheEntry(int connectionId) =>
      _windowSnapshotCache.keys.any((k) => k.connectionId == connectionId);

  /// Returns whether an exec-channel backoff entry exists for [connectionId].
  @visibleForTesting
  static bool hasExecChannelBackoffEntry(int connectionId) =>
      _execChannelBackoffs.containsKey(connectionId);

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
    _tmuxPathRequests.remove(connectionId);
    _hasSessionRequests.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    _installedAgentToolsCache.remove(connectionId);
    _installedAgentToolRequests.remove(connectionId);
    _execChannelBackoffs.remove(connectionId);
    _windowSnapshotCache.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
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

  /// Returns `true` if the primary SSH terminal is attached to tmux.
  ///
  /// This deliberately ignores tmux servers and clients that belong to other
  /// SSH logins on the same host.
  Future<bool> isTmuxActive(SshSession session, {String? extraFlags}) async {
    try {
      return await isTmuxActiveOrThrow(session, extraFlags: extraFlags);
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

  /// Returns `true` if the primary SSH terminal is attached to tmux, and throws
  /// when the remote check could not complete.
  ///
  /// Unlike [isTmuxActive], this distinguishes "not attached to tmux" from
  /// infrastructure failures so callers can preserve existing UI on
  /// indeterminate detection results.
  Future<bool> isTmuxActiveOrThrow(
    SshSession session, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.detect',
      'active_check_start',
      fields: {'connectionId': session.connectionId},
    );
    final active =
        await foregroundSessionNameOrThrow(session, extraFlags: extraFlags) !=
        null;
    DiagnosticsLogService.instance.info(
      'tmux.detect',
      'active_check_complete',
      fields: {'connectionId': session.connectionId, 'active': active},
    );
    return active;
  }

  /// Returns the tmux session attached to the primary SSH terminal, if any.
  Future<String?> foregroundSessionName(
    SshSession session, {
    String? extraFlags,
  }) async {
    try {
      return await foregroundSessionNameOrThrow(
        session,
        extraFlags: extraFlags,
      );
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.query',
        'foreground_session_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Returns the tmux session attached to the primary SSH terminal, and throws
  /// when the remote check could not complete.
  Future<String?> foregroundSessionNameOrThrow(
    SshSession session, {
    String? extraFlags,
  }) => _foregroundSessionNameOrThrow(
    session,
    priority: SshExecPriority.low,
    extraFlags: extraFlags,
  );

  Future<String?> _foregroundSessionNameOrThrow(
    SshSession session, {
    required SshExecPriority priority,
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'foreground_session_start',
      fields: {'connectionId': session.connectionId},
    );
    await _cacheTmuxPath(session);
    final output = await _exec(
      session,
      _buildForegroundTmuxSessionCommand(extraFlags: extraFlags),
      priority: priority,
    );
    final sessionName = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .firstOrNull;
    DiagnosticsLogService.instance.info(
      'tmux.query',
      'foreground_session_complete',
      fields: {
        'connectionId': session.connectionId,
        'active': sessionName != null,
      },
    );
    return sessionName;
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
        if (_isExecChannelCoolingDown(session)) {
          DiagnosticsLogService.instance.debug(
            'tmux.agent',
            'tool_detection_refresh_deferred',
            fields: {'connectionId': session.connectionId},
          );
        } else {
          unawaited(
            _refreshInstalledAgentTools(session, priority: SshExecPriority.low),
          );
        }
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
    if (_isExecChannelCoolingDown(session)) {
      DiagnosticsLogService.instance.debug(
        'tmux.agent',
        'tool_detection_prefetch_deferred',
        fields: {'connectionId': session.connectionId},
      );
      return;
    }
    try {
      await _refreshInstalledAgentTools(session, priority: SshExecPriority.low);
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

  Future<Set<AgentLaunchTool>> _refreshInstalledAgentTools(
    SshSession session, {
    SshExecPriority priority = SshExecPriority.normal,
  }) {
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
      final output = await _exec(
        session,
        buildAgentToolDetectionCommand(),
        priority: priority,
      );
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
  Future<List<TmuxSession>> listSessions(
    SshSession session, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'list_sessions_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final output = await _exec(
        session,
        _tmuxCommand(
          "list-sessions -F '#{session_name}|#{session_windows}|#{session_attached}|#{session_activity}'",
          extraFlags: extraFlags,
        ),
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

  /// Returns the name of the tmux session attached to this terminal.
  ///
  /// This does not infer a session from arbitrary attached tmux clients on the
  /// host; those may belong to other SSH logins.
  Future<String?> currentSessionName(
    SshSession session, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'current_session_start',
      fields: {'connectionId': session.connectionId},
    );
    final foregroundName = await foregroundSessionName(
      session,
      extraFlags: extraFlags,
    );
    if (foregroundName != null) {
      DiagnosticsLogService.instance.info(
        'tmux.query',
        'current_session_foreground',
        fields: {'connectionId': session.connectionId},
      );
      return foregroundName;
    }

    try {
      // Direct approach — works if the exec channel is inside tmux.
      final output = await _exec(
        session,
        _tmuxCommand(
          "display-message -p '#{session_name}'",
          extraFlags: extraFlags,
        ),
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
      // Fall through to an unavailable result.
    }
    DiagnosticsLogService.instance.info(
      'tmux.query',
      'current_session_unavailable',
      fields: {'connectionId': session.connectionId},
    );
    return null;
  }

  /// Returns `true` if [sessionName] exists on the remote tmux server.
  Future<bool> hasSession(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    try {
      return await hasSessionOrThrow(
        session,
        sessionName,
        extraFlags: extraFlags,
      );
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

  /// Returns `true` if [sessionName] exists, and throws when the remote check
  /// could not complete.
  ///
  /// Unlike [hasSession], this distinguishes a missing tmux session from
  /// transient SSH exec/channel failures.
  Future<bool> hasSessionOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final requestKey = _TmuxSessionRequestKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    final existingRequest = _hasSessionRequests[requestKey];
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.query',
        'has_session_join',
        fields: {
          'connectionId': session.connectionId,
          'sessionHash': sessionName.hashCode.abs(),
        },
      );
      return existingRequest;
    }

    final request = _hasSessionOrThrow(
      session,
      sessionName,
      extraFlags: extraFlags,
    );
    _hasSessionRequests[requestKey] = request;
    request.whenComplete(() {
      if (identical(_hasSessionRequests[requestKey], request)) {
        _hasSessionRequests.remove(requestKey);
      }
    }).ignore();
    return request;
  }

  Future<bool> _hasSessionOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'has_session_start',
      fields: {'connectionId': session.connectionId},
    );
    await _cacheTmuxPath(session);
    final output = await _exec(
      session,
      '${_tmuxCommand('has-session -t ${_shellQuote(sessionName)}', extraFlags: extraFlags)} 2>/dev/null; '
      r'status=$?; '
      r'if [ "$status" -eq 0 ]; then printf 1; '
      r'elif [ "$status" -eq 1 ]; then printf 0; '
      'else false; fi',
      priority: SshExecPriority.low,
    );
    final exists = output.trim() == '1';
    DiagnosticsLogService.instance.info(
      'tmux.query',
      'has_session_complete',
      fields: {'connectionId': session.connectionId, 'exists': exists},
    );
    return exists;
  }

  // ── Window queries ─────────────────────────────────────────────────────

  /// Lists all windows in the given tmux [sessionName].
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    if (_isExecChannelCoolingDown(session) &&
        _controlCommandObserver(
              session,
              sessionName,
              extraFlags: extraFlags,
            )?.canRunCommands !=
            true) {
      final cachedWindows = _windowSnapshotCache[key];
      if (cachedWindows != null && cachedWindows.isNotEmpty) {
        DiagnosticsLogService.instance.warning(
          'tmux.query',
          'list_windows_cached_during_backoff',
          fields: {
            'connectionId': session.connectionId,
            'windowCount': cachedWindows.length,
          },
        );
        return cachedWindows;
      }
    }
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

    final request = _listWindows(session, sessionName, extraFlags: extraFlags);
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
    String sessionName, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'list_windows_start',
      fields: {'connectionId': session.connectionId},
    );
    final quotedName = _shellQuote(sessionName);
    try {
      final output = await _execTmuxCommand(
        session,
        sessionName,
        'list-windows -t $quotedName -F '
        '${_shellQuote(_tmuxWindowSubscriptionFormat)}',
        extraFlags: extraFlags,
        forceUtf8: true,
      );
      final windows = List<TmuxWindow>.unmodifiable(
        _parseLines(output, TmuxWindow.fromTmuxFormat),
      );
      if (windows.isNotEmpty) {
        _cacheWindowSnapshot(
          session,
          sessionName,
          windows,
          extraFlags: extraFlags,
        );
      }
      DiagnosticsLogService.instance.info(
        'tmux.query',
        'list_windows_complete',
        fields: {
          'connectionId': session.connectionId,
          'windowCount': windows.length,
          'activeWindowCount': windows
              .where((window) => window.isActive)
              .length,
          'alertWindowCount': windows.where((window) => window.hasAlert).length,
        },
      );
      return windows;
    } on Object catch (error) {
      final cachedWindows =
          _windowSnapshotCache[_TmuxWindowWatchKey(
            connectionId: session.connectionId,
            sessionName: sessionName,
            extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
          )];
      if (cachedWindows != null &&
          cachedWindows.isNotEmpty &&
          shouldUseCachedTmuxWindowsAfterListFailure(error)) {
        DiagnosticsLogService.instance.warning(
          'tmux.query',
          'list_windows_cached_after_failure',
          fields: {
            'connectionId': session.connectionId,
            'windowCount': cachedWindows.length,
            'errorType': error.runtimeType,
          },
        );
        return cachedWindows;
      }
      rethrow;
    }
  }

  /// Returns the active pane working directory for [sessionName], if tmux
  /// reports one.
  Future<String?> currentPanePath(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'current_pane_path_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final output = await _execTmuxCommand(
        session,
        sessionName,
        "display-message -p -t ${_shellQuote('$sessionName:')} "
        "'#{pane_current_path}'",
        extraFlags: extraFlags,
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

  /// Returns whether [sessionName] is attached in the primary SSH terminal.
  ///
  /// Control-mode observers are excluded by the foreground-session probe
  /// because MonkeySSH uses one for live window updates even after the visible
  /// interactive shell has left tmux.
  Future<bool> hasForegroundClient(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    try {
      return await hasForegroundClientOrThrow(
        session,
        sessionName,
        extraFlags: extraFlags,
      );
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

  /// Returns whether [sessionName] is attached in the primary SSH terminal, and
  /// throws when the remote check could not complete.
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.query',
      'foreground_client_start',
      fields: {'connectionId': session.connectionId},
    );
    final foregroundSessionName = await _foregroundSessionNameOrThrow(
      session,
      priority: SshExecPriority.normal,
      extraFlags: extraFlags,
    );
    final hasClient = foregroundSessionName == sessionName;
    DiagnosticsLogService.instance.info(
      'tmux.query',
      'foreground_client_complete',
      fields: {
        'connectionId': session.connectionId,
        'hasForegroundClient': hasClient,
        'hasForegroundSession': foregroundSessionName != null,
      },
    );
    return hasClient;
  }

  /// Asks every foreground client attached to [sessionName] to redraw.
  Future<void> refreshForegroundClients(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.action',
      'refresh_clients_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      await _exec(
        session,
        buildTmuxRefreshForegroundClientsCommand(
          sessionName,
          extraFlags: extraFlags,
        ),
      );
      DiagnosticsLogService.instance.info(
        'tmux.action',
        'refresh_clients_complete',
        fields: {'connectionId': session.connectionId},
      );
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.action',
        'refresh_clients_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  /// Updates tmux's pane palette for [sessionName] and redraws foreground
  /// clients.
  Future<void> refreshTerminalTheme(
    SshSession session,
    String sessionName,
    TerminalThemeData theme, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.debug(
      'tmux.action',
      'refresh_theme_start',
      fields: {'connectionId': session.connectionId},
    );
    try {
      final output = await _exec(
        session,
        buildTmuxRefreshTerminalThemeCommand(
          sessionName,
          theme,
          extraFlags: extraFlags,
        ),
      );
      final stats = _parseTmuxThemeRefreshStats(output);
      DiagnosticsLogService.instance.info(
        'tmux.action',
        'refresh_theme_complete',
        fields: {
          'connectionId': session.connectionId,
          if (stats != null) ...{
            'paneCount': stats.paneCount,
            'activePaneCount': stats.activePaneCount,
            'alternatePaneCount': stats.alternatePaneCount,
            'injectedPaneCount': stats.injectedPaneCount,
          },
        },
      );
    } on Exception catch (error) {
      DiagnosticsLogService.instance.warning(
        'tmux.action',
        'refresh_theme_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
    }
  }

  /// Watches tmux control-mode notifications that indicate window state
  /// has changed for [sessionName].
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) {
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    final observer = _windowObservers.putIfAbsent(
      key,
      () => _TmuxWindowChangeObserver(
        service: this,
        session: session,
        sessionName: sessionName,
        extraFlags: extraFlags,
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
    String? extraFlags,
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
      "new-window -P -F '#{window_index}' -t ${_shellQuote(sessionName)}",
      if (workingDirectory != null && workingDirectory.trim().isNotEmpty)
        '-c ${_shellQuote(workingDirectory.trim())}',
      if (name != null && name.trim().isNotEmpty)
        '-n ${_shellQuote(name.trim())}',
    ];
    final createdWindowIndex = _parseCreatedWindowIndex(
      await _execTmuxCommand(
        session,
        sessionName,
        parts.join(' '),
        extraFlags: extraFlags,
      ),
    );
    final target = createdWindowIndex == null
        ? sessionName
        : '$sessionName:$createdWindowIndex';
    final agentTool = _agentToolForCreatedWindow(command: command, name: name);
    if (agentTool != null) {
      await _execTmuxCommand(
        session,
        sessionName,
        'set-option -w -t ${_shellQuote(target)} '
        '@flutty_agent_tool ${_shellQuote(agentTool.commandName)}',
        extraFlags: extraFlags,
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
      _execTmuxCommandFireAndForget(
        session,
        sessionName,
        'send-keys -t ${_shellQuote(target)} '
        '${_shellQuote(command.trim())} Enter',
        extraFlags: extraFlags,
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
    int windowIndex, {
    String? windowId,
    String? extraFlags,
  }) async {
    final targetWindowId = windowId?.trim();
    final safeWindowId =
        targetWindowId != null && isValidTmuxWindowId(targetWindowId)
        ? targetWindowId
        : null;
    final hasTargetWindowId = safeWindowId != null;
    final target = safeWindowId == null
        ? '${_shellQuote(sessionName)}:$windowIndex'
        : _shellQuote(safeWindowId);
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'select_window_start',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
        'hasWindowId': hasTargetWindowId,
      },
    );
    await _execTmuxCommand(
      session,
      sessionName,
      'select-window -t $target',
      extraFlags: extraFlags,
    );
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'select_window_complete',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
        'hasWindowId': hasTargetWindowId,
      },
    );
  }

  /// Closes a window in [sessionName] via exec channel.
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? extraFlags,
  }) async {
    DiagnosticsLogService.instance.info(
      'tmux.action',
      'kill_window_start',
      fields: {
        'connectionId': session.connectionId,
        'windowIndex': windowIndex,
      },
    );
    await _execTmuxCommand(
      session,
      sessionName,
      'kill-window -t ${_shellQuote(sessionName)}:$windowIndex',
      extraFlags: extraFlags,
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

  bool _isExecChannelCoolingDown(SshSession session) {
    final backoff = _execChannelBackoffs[session.connectionId];
    if (backoff == null) return false;
    if (backoff.cooldownUntil.isAfter(DateTime.now())) {
      return true;
    }
    _execChannelBackoffs.remove(session.connectionId);
    return false;
  }

  /// Returns whether optional SSH exec-channel work should be deferred.
  bool isExecChannelCoolingDown(SshSession session) =>
      _isExecChannelCoolingDown(session);

  void _recordExecChannelFailure(int connectionId, Object error) {
    final failureCount =
        (_execChannelBackoffs[connectionId]?.failureCount ?? 0) + 1;
    final delay = resolveTmuxExecChannelBackoffDelay(failureCount);
    _execChannelBackoffs[connectionId] = _TmuxExecChannelBackoff(
      failureCount: failureCount,
      cooldownUntil: DateTime.now().add(delay),
    );
    DiagnosticsLogService.instance.warning(
      'tmux.exec',
      'channel_backoff',
      fields: {
        'connectionId': connectionId,
        'failureCount': failureCount,
        'delayMs': delay.inMilliseconds,
        'errorType': error.runtimeType,
      },
    );
  }

  void _clearExecChannelBackoff(int connectionId) {
    if (_execChannelBackoffs.remove(connectionId) != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.exec',
        'channel_backoff_cleared',
        fields: {'connectionId': connectionId},
      );
    }
  }

  void _cacheWindowSnapshot(
    SshSession session,
    String sessionName,
    List<TmuxWindow> windows, {
    String? extraFlags,
  }) {
    if (windows.isEmpty) return;
    _windowSnapshotCache[_TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    )] = List<TmuxWindow>.unmodifiable(
      windows,
    );
  }

  void _applyCachedWindowEvent(
    SshSession session,
    String sessionName,
    TmuxWindowChangeEvent event, {
    String? extraFlags,
  }) {
    final key = _TmuxWindowWatchKey(
      connectionId: session.connectionId,
      sessionName: sessionName,
      extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
    );
    final cachedWindows = _windowSnapshotCache[key];
    if (cachedWindows == null || cachedWindows.isEmpty) return;
    _windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable(
      applyTmuxWindowChangeEvent(cachedWindows, event),
    );
  }

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
    if (trimmed == 'tmux -u' || trimmed.startsWith('tmux -u ')) {
      return command;
    }
    return command.replaceFirst('tmux ', 'tmux -u ');
  }

  /// Opens an SSH exec channel with a bounded wait for channel creation.
  Future<SSHSession> _openExec(
    SshSession session,
    String command, {
    SSHPtyConfig? pty,
  }) async {
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
    try {
      final exec = await openFuture.timeout(
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
      _clearExecChannelBackoff(session.connectionId);
      return exec;
    } on Object catch (error) {
      if (shouldBackOffTmuxExecChannelAfterFailure(error)) {
        _recordExecChannelFailure(session.connectionId, error);
      }
      rethrow;
    }
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
  Future<String> _exec(
    SshSession session,
    String command, {
    SshExecPriority priority = SshExecPriority.normal,
  }) => session.runQueuedExec(
    () => _execUnqueued(session, command),
    priority: priority,
  );

  Future<String> _execTmuxCommand(
    SshSession session,
    String sessionName,
    String tmuxCommand, {
    String? extraFlags,
    bool forceUtf8 = false,
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    final controlOutput = await _tryControlCommand(
      session,
      sessionName,
      tmuxCommand,
      extraFlags: extraFlags,
    );
    if (controlOutput != null) {
      return controlOutput;
    }
    return _exec(
      session,
      _tmuxCommand(tmuxCommand, extraFlags: extraFlags, forceUtf8: forceUtf8),
      priority: priority,
    );
  }

  Future<String?> _tryControlCommand(
    SshSession session,
    String sessionName,
    String tmuxCommand, {
    String? extraFlags,
  }) async {
    final observer = _controlCommandObserver(
      session,
      sessionName,
      extraFlags: extraFlags,
    );
    if (observer == null) {
      return null;
    }
    try {
      return await observer.runCommand(
        tmuxCommand,
        commandKind: _diagnosticTmuxCommandKind(tmuxCommand),
        timeout: _execOutputTimeout,
      );
    } on _TmuxControlCommandUnavailable {
      return null;
    }
  }

  _TmuxWindowChangeObserver? _controlCommandObserver(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) =>
      _windowObservers[_TmuxWindowWatchKey(
        connectionId: session.connectionId,
        sessionName: sessionName,
        extraFlags: resolveTmuxClientFlagsFromExtraFlags(extraFlags),
      )];

  Future<String> _execUnqueued(SshSession session, String command) async {
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
  /// Used for follow-up operations where completion does not need to block the
  /// caller, but still closes the exec channel once the command marker returns.
  void _execTmuxCommandFireAndForget(
    SshSession session,
    String sessionName,
    String tmuxCommand, {
    String? extraFlags,
  }) {
    final commandKind = _diagnosticTmuxCommandKind(tmuxCommand);
    DiagnosticsLogService.instance.debug(
      'tmux.exec',
      'fire_and_forget_start',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': commandKind,
      },
    );
    final controlObserver = _controlCommandObserver(
      session,
      sessionName,
      extraFlags: extraFlags,
    );
    final commandFuture =
        controlObserver?.runCommand(
          tmuxCommand,
          commandKind: commandKind,
          timeout: _execOutputTimeout,
        ) ??
        _exec(session, _tmuxCommand(tmuxCommand, extraFlags: extraFlags));
    commandFuture.catchError((Object error) {
      DiagnosticsLogService.instance.warning(
        'tmux.exec',
        'fire_and_forget_failed',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': commandKind,
          'errorType': error.runtimeType,
        },
      );
      return '';
    }).ignore();
  }

  /// Detects the user's login shell and resolves the tmux binary path.
  ///
  /// Caches both the shell-specific profile source command and the
  /// full tmux path for subsequent calls.
  Future<void> _cacheTmuxPath(SshSession session) async {
    if (_tmuxPathCache.containsKey(session.connectionId)) return;
    final existingRequest = _tmuxPathRequests[session.connectionId];
    if (existingRequest != null) {
      DiagnosticsLogService.instance.debug(
        'tmux.cache',
        'tmux_path_join',
        fields: {'connectionId': session.connectionId},
      );
      try {
        await existingRequest;
      } on Object {
        // The owner logs probe failures; joiners keep the same fallback path.
      }
      return;
    }
    DiagnosticsLogService.instance.debug(
      'tmux.cache',
      'tmux_path_start',
      fields: {'connectionId': session.connectionId},
    );
    final request = () async {
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
        priority: SshExecPriority.low,
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
    }();
    _tmuxPathRequests[session.connectionId] = request;
    try {
      await request;
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
    } finally {
      if (identical(_tmuxPathRequests[session.connectionId], request)) {
        _tmuxPathRequests.remove(session.connectionId)?.ignore();
      }
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

class _TmuxExecChannelBackoff {
  const _TmuxExecChannelBackoff({
    required this.failureCount,
    required this.cooldownUntil,
  });

  final int failureCount;
  final DateTime cooldownUntil;
}

/// Returns whether a failed tmux exec open should trigger channel backoff.
@visibleForTesting
bool shouldBackOffTmuxExecChannelAfterFailure(Object error) =>
    error is SSHChannelOpenError || error is TimeoutException;

/// Returns whether stale tmux windows are safer than failing a refresh.
@visibleForTesting
bool shouldUseCachedTmuxWindowsAfterListFailure(Object error) =>
    shouldBackOffTmuxExecChannelAfterFailure(error);

/// Resolves the tmux exec channel cooldown after repeated open failures.
@visibleForTesting
Duration resolveTmuxExecChannelBackoffDelay(int failureCount) {
  final retryAttempt = failureCount <= 1 ? 0 : failureCount - 1;
  return resolveTmuxWindowReloadRetryDelay(retryAttempt);
}

/// Resolves how quickly the control-mode watcher should restart.
@visibleForTesting
Duration resolveTmuxControlRestartDelay(
  int restartAttempts, {
  required bool channelOpenFailure,
}) {
  if (channelOpenFailure) {
    return resolveTmuxWindowReloadRetryDelay(
      restartAttempts,
      initialDelay: const Duration(seconds: 5),
    );
  }
  final cappedAttempt = restartAttempts.clamp(0, 4);
  return Duration(seconds: 1 << cappedAttempt);
}

String _diagnosticTmuxCommandKind(String command) {
  if (command.contains('flutty_theme_refresh_pane')) {
    return 'refresh_theme';
  }
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

String _buildForegroundTmuxSessionCommand({String? extraFlags}) {
  final listClients = TmuxService._tmuxCommand(
    'list-clients -F ',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  return r'sep=$(printf "\037"); '
      r'connection_pid=$(ps -p "$$" -o ppid= 2>/dev/null | tr -d " "); '
      r'if [ -n "$connection_pid" ]; then '
      '$listClients"#{client_pid}\$sep#{session_name}\$sep#{client_control_mode}" '
      '2>/dev/null | '
      r'while IFS="$sep" read -r client_pid session_name control_mode; do '
      r'[ "$control_mode" = 0 ] || continue; '
      r'[ -n "$client_pid" ] && [ -n "$session_name" ] || continue; '
      r'pid="$client_pid"; '
      r'while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do '
      r'if [ "$pid" = "$connection_pid" ]; then '
      r'printf "%s\n" "$session_name"; '
      'break 2; '
      'fi; '
      r'pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d " "); '
      'done; '
      'done; '
      'fi';
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

/// Builds a command that redraws all non-control tmux clients for a session.
@visibleForTesting
String buildTmuxRefreshForegroundClientsCommand(
  String sessionName, {
  String? extraFlags,
}) {
  const sep = r'${SEP}';
  final listClients = TmuxService._tmuxCommand(
    'list-clients -t ${TmuxService._shellQuote(sessionName)} -F ',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  final refreshClient = TmuxService._tmuxCommand(
    r'refresh-client -t "$client"',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  return r'SEP=$(printf "\037"); '
      '$listClients"#{client_control_mode}$sep#{client_name}" '
      '2>/dev/null | '
      r'while IFS="$SEP" read -r control client; do '
      r'[ "$control" = 0 ] || continue; '
      r'[ -n "$client" ] || continue; '
      '$refreshClient 2>/dev/null || true; '
      'done';
}

// Only write synthetic reports directly into panes for known theme-aware TUIs.
// Short-lived commands such as `git` can hand those bytes to the next shell
// prompt, where zsh/bash treat OSC response fragments as commands/paths.
const _tmuxThemeRefreshTuiCommandPatterns = <String>[
  'claude',
  'claude-*',
  'copilot',
  'copilot-*',
  'codex',
  'codex-*',
  'opencode',
  'opencode-*',
  'gemini',
  'gemini-*',
];

const _tmuxThemeRefreshTuiTitlePatterns = <String>[
  '*Claude*',
  '*claude*',
  '*Copilot*',
  '*copilot*',
  '*Codex*',
  '*codex*',
  '*OpenCode*',
  '*opencode*',
  '*Gemini*',
  '*gemini*',
];

/// Builds a command that updates tmux's pane palette, notifies theme-aware TUI
/// panes, and redraws foreground clients.
@visibleForTesting
String buildTmuxRefreshTerminalThemeCommand(
  String sessionName,
  TerminalThemeData theme, {
  String? extraFlags,
}) {
  const sep = r'${SEP}';
  final themeRefreshTuiCommandPatterns = _tmuxThemeRefreshTuiCommandPatterns
      .join('|');
  final themeRefreshTuiTitlePatterns = _tmuxThemeRefreshTuiTitlePatterns.join(
    '|',
  );
  final listPanes = TmuxService._tmuxCommand(
    'list-panes -s -t ${TmuxService._shellQuote(sessionName)} -F ',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  final setPaneColours = _buildTmuxSetPaneColoursCommand(
    theme,
    extraFlags: extraFlags,
  );
  final provideClientThemeReports = _buildTmuxProvideClientThemeReportsCommand(
    sessionName,
    theme,
    extraFlags: extraFlags,
  );
  // Make sure tmux forwards focus events to inner panes — without this,
  // theme-aware TUIs like Codex/Copilot CLI never receive the FocusGained
  // signal we use as the trigger to re-query OSC 10/11 after a theme switch
  // and their cached default fg/bg stay stale (e.g. input composer "stuck
  // almost black"). Safe to re-apply on every refresh because the option is
  // global and idempotent.
  final enableFocusEvents = TmuxService._tmuxCommand(
    'set-option -g focus-events on',
    extraFlags: extraFlags,
    forceUtf8: true,
  );

  return r'SEP=$(printf "\037"); '
      '$enableFocusEvents 2>/dev/null || true; '
      '$listPanes"#{pane_id}$sep#{pane_active}$sep#{alternate_on}$sep#{pane_current_command}$sep#{pane_title}" '
      '2>/dev/null | '
      r'{ while IFS="$SEP" read -r pane active alternate pane_command pane_title; do '
      r'[ -n "$pane" ] || continue; '
      '$setPaneColours '
      '$provideClientThemeReports '
      'injected=0; theme_refresh_tui=0; '
      r'case "${pane_command##*/}" in '
      '$themeRefreshTuiCommandPatterns) theme_refresh_tui=1 ;; '
      'esac; '
      r'case "$pane_title" in '
      '$themeRefreshTuiTitlePatterns) theme_refresh_tui=1 ;; '
      'esac; '
      r'if [ "$theme_refresh_tui" = 1 ]; then '
      'injected=1; '
      r'case "${pane_command##*/}" in '
      'copilot|copilot-*|codex|codex-*) '
      '( ${_buildTmuxSendPaneFocusRefreshCommand(extraFlags: extraFlags)} '
      '2>/dev/null || true ) & ;; '
      'opencode|opencode-*) '
      '( ${_buildTmuxSendPaneTerminalThemeCommand(theme, extraFlags: extraFlags, forceFocusTransition: true, includeLateFocusTransition: true)} ) & ;; '
      '*) '
      r'case "$pane_title" in '
      '*Copilot*|*copilot*|*Codex*|*codex*) '
      '( ${_buildTmuxSendPaneFocusRefreshCommand(extraFlags: extraFlags)} '
      '2>/dev/null || true ) & ;; '
      '*OpenCode*|*opencode*) '
      '( ${_buildTmuxSendPaneTerminalThemeCommand(theme, extraFlags: extraFlags, forceFocusTransition: true, includeLateFocusTransition: true)} ) & ;; '
      '*) '
      '( ${_buildTmuxSendPaneTerminalThemeCommand(theme, extraFlags: extraFlags)} ) & ;; '
      'esac ;; '
      'esac; '
      'fi; '
      r'printf "flutty_theme_refresh_pane:%s,%s,%s\n" "$active" "$alternate" "$injected"; '
      'done; wait; }; '
      '${buildTmuxRefreshForegroundClientsCommand(sessionName, extraFlags: extraFlags)}';
}

class _TmuxThemeRefreshStats {
  const _TmuxThemeRefreshStats({
    required this.paneCount,
    required this.activePaneCount,
    required this.alternatePaneCount,
    required this.injectedPaneCount,
  });

  final int paneCount;
  final int activePaneCount;
  final int alternatePaneCount;
  final int injectedPaneCount;
}

_TmuxThemeRefreshStats? _parseTmuxThemeRefreshStats(String output) {
  var paneCount = 0;
  var activePaneCount = 0;
  var alternatePaneCount = 0;
  var injectedPaneCount = 0;
  for (final line in output.split('\n')) {
    if (!line.startsWith('flutty_theme_refresh_pane:')) {
      continue;
    }
    final fields = line
        .substring('flutty_theme_refresh_pane:'.length)
        .split(',');
    if (fields.length != 3) {
      continue;
    }
    paneCount += 1;
    if (fields[0] == '1') {
      activePaneCount += 1;
    }
    if (fields[1] == '1') {
      alternatePaneCount += 1;
    }
    if (fields[2] == '1') {
      injectedPaneCount += 1;
    }
  }
  if (paneCount == 0) {
    return null;
  }
  return _TmuxThemeRefreshStats(
    paneCount: paneCount,
    activePaneCount: activePaneCount,
    alternatePaneCount: alternatePaneCount,
    injectedPaneCount: injectedPaneCount,
  );
}

String _buildTmuxSetPaneColoursCommand(
  TerminalThemeData theme, {
  String? extraFlags,
}) {
  final commands = <String>[
    for (var index = 0; index < 16; index += 1)
      _buildTmuxSetPaneColourSubcommand(index, theme),
  ];
  final command = TmuxService._tmuxCommand(
    commands.join(r' \; '),
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  return '$command 2>/dev/null || true;';
}

String _buildTmuxSetPaneColourSubcommand(int index, TerminalThemeData theme) {
  final color = terminalThemePaletteColor(theme, index);
  if (color == null) {
    throw ArgumentError.value(index, 'index', 'Expected ANSI color index 0-15');
  }
  final hexColor = formatTerminalThemeRgbHex(color);
  final optionName = TmuxService._shellQuote('pane-colours[$index]');
  return r'set-option -p -t "$pane" '
      '$optionName ${TmuxService._shellQuote(hexColor)}';
}

String _buildTmuxProvideClientThemeReportsCommand(
  String sessionName,
  TerminalThemeData theme, {
  String? extraFlags,
}) {
  final reports = [
    buildTerminalThemeModeReport(isDark: theme.isDark),
    buildTerminalThemeOscResponse(theme: theme, code: '10', args: const ['?']),
    buildTerminalThemeOscResponse(theme: theme, code: '11', args: const ['?']),
  ].whereType<String>().toList(growable: false);
  if (reports.isEmpty) {
    return '';
  }

  const sep = r'${SEP}';
  final listClients = TmuxService._tmuxCommand(
    'list-clients -t ${TmuxService._shellQuote(sessionName)} -F ',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  final refreshReports = reports
      .map((report) {
        final reportCommand = TmuxService._tmuxCommand(
          '${r'refresh-client -t "$client" -r "$pane":'}'
          '${TmuxService._shellQuote(report)}',
          extraFlags: extraFlags,
          forceUtf8: true,
        );
        return '$reportCommand 2>/dev/null || true;';
      })
      .join(' ');

  return '$listClients"#{client_name}$sep#{client_control_mode}" '
      '2>/dev/null | '
      r'while IFS="$SEP" read -r client _control; do '
      r'[ -n "$client" ] || continue; '
      '$refreshReports '
      'done;';
}

String _buildTmuxSendPaneTerminalThemeCommand(
  TerminalThemeData theme, {
  String? extraFlags,
  bool forceFocusTransition = false,
  bool includeLateFocusTransition = false,
}) {
  final themeModeReport = buildTerminalThemeModeReport(isDark: theme.isDark);
  final defaultColorReports = buildTerminalThemeDefaultColorReports(theme);
  // Do not inject unsolicited OSC 4 palette replies into the pane. Apps such
  // as Codex can treat palette replies they did not request as user input; the
  // tmux pane palette update above ensures any subsequent OSC 4 query sees
  // fresh colors without writing palette bytes to the foreground app.
  //
  // OSC 10/11 default color replies are intentionally sent after the private
  // mode report. That gives OpenTUI/OpenCode a complete theme-mode plus default
  // color cycle even when tmux consumes the outer OSC responses. Codex panes
  // are routed to the focus-only refresh above because unsolicited mode/color
  // reports can reset its composer input while the user is typing.
  final focusCommand = forceFocusTransition
      ? _buildTmuxSendPaneFocusTransitionCommand(extraFlags: extraFlags)
      : _buildTmuxSendPaneFocusRefreshCommand(extraFlags: extraFlags);
  final lateFocusCommand = includeLateFocusTransition
      ? ' sleep 0.08; '
            '${_buildTmuxSendPaneFocusTransitionCommand(extraFlags: extraFlags)} '
            '2>/dev/null || true;'
      : '';
  final modeCommand = TmuxService._tmuxCommand(
    r'send-keys -t "$pane" -H '
    '${_formatTmuxSendKeysHexArguments(themeModeReport)}',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  final directColorCommand = TmuxService._tmuxCommand(
    r'send-keys -t "$pane" -H '
    '${_formatTmuxSendKeysHexArguments(defaultColorReports)}',
    extraFlags: extraFlags,
    forceUtf8: true,
  );
  return '$focusCommand 2>/dev/null || true; '
      'sleep 0.25; '
      '$modeCommand 2>/dev/null || true;'
      ' sleep 0.08; '
      '$directColorCommand 2>/dev/null || true;'
      ' sleep 0.08; '
      '$directColorCommand 2>/dev/null || true;'
      ' sleep 0.08; '
      '$directColorCommand 2>/dev/null || true;'
      '$lateFocusCommand';
}

String _buildTmuxSendPaneFocusRefreshCommand({String? extraFlags}) =>
    _buildTmuxSendPaneFocusReportCommand('\x1b[I', extraFlags: extraFlags);

String _buildTmuxSendPaneFocusTransitionCommand({String? extraFlags}) =>
    '${_buildTmuxSendPaneFocusReportCommand('\x1b[O', extraFlags: extraFlags)} '
    '2>/dev/null || true; sleep 0.12; '
    '${_buildTmuxSendPaneFocusReportCommand('\x1b[I', extraFlags: extraFlags)}';

String _buildTmuxSendPaneFocusReportCommand(
  String report, {
  String? extraFlags,
}) => TmuxService._tmuxCommand(
  r'send-keys -t "$pane" -H '
  '${_formatTmuxSendKeysHexArguments(report)}',
  extraFlags: extraFlags,
  forceUtf8: true,
);

String _formatTmuxSendKeysHexArguments(String input) =>
    input.codeUnits.map(_formatTmuxSendKeysHexArgument).join(' ');

String _formatTmuxSendKeysHexArgument(int codeUnit) {
  if (codeUnit > 0x7F) {
    throw ArgumentError.value(
      codeUnit,
      'codeUnit',
      'Expected an ASCII terminal response byte',
    );
  }
  return codeUnit.toRadixString(16).padLeft(2, '0');
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

/// Extracts only tmux client/server flags that can be reused with commands
/// other than `new-session`.
@visibleForTesting
String? resolveTmuxClientFlagsFromExtraFlags(String? extraFlags) {
  final tokens = _tokenizeShellFragment(extraFlags);
  if (tokens == null || tokens.isEmpty) {
    return null;
  }

  final clientFlags = <String>[];
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    if (_isTmuxCommandSeparatorToken(token.value)) {
      break;
    }
    if (!_isReusableTmuxClientFlag(token.value)) {
      continue;
    }
    if (token.value.length > 2) {
      clientFlags.add(_buildReusableTmuxClientFlag(token.value));
      continue;
    }
    if (index + 1 >= tokens.length ||
        _isTmuxCommandSeparatorToken(tokens[index + 1].value)) {
      continue;
    }
    clientFlags.add(
      '${token.value} ${_shellQuoteReusableTmuxClientFlagValue(tokens[index + 1].value)}',
    );
    index++;
  }

  return clientFlags.isEmpty ? null : clientFlags.join(' ');
}

String _buildReusableTmuxClientFlag(String tokenValue) {
  final flag = tokenValue.substring(0, 2);
  final value = tokenValue.substring(2);
  return '$flag ${_shellQuoteReusableTmuxClientFlagValue(value)}';
}

String _shellQuoteReusableTmuxClientFlagValue(String value) {
  if (value == '~') {
    return r'"$HOME"';
  }
  if (value.startsWith('~/')) {
    return r'"$HOME"' + TmuxService._shellQuote(value.substring(1));
  }
  return TmuxService._shellQuote(value);
}

List<_ShellToken>? _tokenizeShellFragment(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) {
    return const [];
  }
  if (normalized.contains('\n') || normalized.contains('\r')) {
    return null;
  }

  final tokens = <_ShellToken>[];
  var currentToken = StringBuffer();
  var tokenStarted = false;
  var tokenStart = 0;
  var quoteMode = _ShellQuoteMode.none;

  void startToken(int index) {
    if (tokenStarted) {
      return;
    }
    tokenStarted = true;
    tokenStart = index;
  }

  void commitToken(int end) {
    if (!tokenStarted) {
      return;
    }
    tokens.add(
      _ShellToken(
        value: currentToken.toString(),
        raw: normalized.substring(tokenStart, end),
      ),
    );
    currentToken = StringBuffer();
    tokenStarted = false;
  }

  for (var index = 0; index < normalized.length; index++) {
    final character = normalized[index];

    if (quoteMode == _ShellQuoteMode.single) {
      if (character == "'") {
        quoteMode = _ShellQuoteMode.none;
      } else {
        startToken(index);
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
          return null;
        }
        final nextCharacter = normalized[index + 1];
        if (nextCharacter == '"' ||
            nextCharacter.codeUnitAt(0) == _backslashCodeUnit ||
            nextCharacter == r'$' ||
            nextCharacter == '`') {
          startToken(index);
          currentToken.write(nextCharacter);
          index++;
          continue;
        }
      }
      startToken(index);
      currentToken.write(character);
      continue;
    }

    if (character == ' ' || character == '\t') {
      commitToken(index);
      continue;
    }
    if (character == "'") {
      startToken(index);
      quoteMode = _ShellQuoteMode.single;
      continue;
    }
    if (character == '"') {
      startToken(index);
      quoteMode = _ShellQuoteMode.double;
      continue;
    }
    if (character.codeUnitAt(0) == _backslashCodeUnit) {
      if (index + 1 >= normalized.length) {
        return null;
      }
      startToken(index);
      currentToken.write(normalized[index + 1]);
      index++;
      continue;
    }
    startToken(index);
    currentToken.write(character);
  }

  if (quoteMode != _ShellQuoteMode.none) {
    return null;
  }

  commitToken(normalized.length);
  return tokens;
}

bool _isReusableTmuxClientFlag(String value) {
  if (value == '-S' || value == '-L' || value == '-f') {
    return true;
  }
  return value.length > 2 &&
      (value.startsWith('-S') ||
          value.startsWith('-L') ||
          value.startsWith('-f'));
}

bool _isTmuxCommandSeparatorToken(String value) => value == ';';

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
    '#{@flutty_agent_tool}$tmuxWindowFieldSeparator'
    '#{window_id}';

const _tmuxControlModeClientFlags = 'ignore-size,no-output,wait-exit';

/// Builds the tmux control-mode attach command used for live window updates.
@visibleForTesting
String buildTmuxControlModeAttachCommand(
  String sessionName, {
  String? extraFlags,
}) =>
    '${TmuxService._tmuxCommand('-CC attach-session -f $_tmuxControlModeClientFlags', extraFlags: extraFlags)} '
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
class _TmuxSessionRequestKey {
  const _TmuxSessionRequestKey({
    required this.connectionId,
    required this.sessionName,
    this.extraFlags,
  });

  final int connectionId;
  final String sessionName;
  final String? extraFlags;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TmuxSessionRequestKey &&
          connectionId == other.connectionId &&
          sessionName == other.sessionName &&
          extraFlags == other.extraFlags;

  @override
  int get hashCode => Object.hash(connectionId, sessionName, extraFlags);
}

@immutable
class _TmuxWindowWatchKey {
  const _TmuxWindowWatchKey({
    required this.connectionId,
    required this.sessionName,
    this.extraFlags,
  });

  final int connectionId;
  final String sessionName;
  final String? extraFlags;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TmuxWindowWatchKey &&
          connectionId == other.connectionId &&
          sessionName == other.sessionName &&
          extraFlags == other.extraFlags;

  @override
  int get hashCode => Object.hash(connectionId, sessionName, extraFlags);
}

class _TmuxControlCommandUnavailable implements Exception {
  const _TmuxControlCommandUnavailable();
}

class _TmuxControlCommandRequest {
  _TmuxControlCommandRequest({
    required this.command,
    required this.commandKind,
    required this.timeout,
  });

  final String command;
  final String commandKind;
  final Duration timeout;
  final output = StringBuffer();
  final _completer = Completer<String>();
  Timer? _timeoutTimer;
  bool started = false;

  Future<String> get future => _completer.future;

  void startTimeout(void Function() onTimeout) {
    _timeoutTimer = Timer(timeout, onTimeout);
  }

  void cancelTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
  }

  void complete(String value) {
    cancelTimeout();
    if (!_completer.isCompleted) {
      _completer.complete(value);
    }
  }

  void completeError(Object error, StackTrace stackTrace) {
    cancelTimeout();
    if (!_completer.isCompleted) {
      _completer.completeError(error, stackTrace);
    }
  }
}

class _TmuxWindowChangeObserver {
  _TmuxWindowChangeObserver({
    required this.service,
    required this.session,
    required this.sessionName,
    required this.onDispose,
    this.extraFlags,
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
  final String? extraFlags;
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
  final _controlCommandQueue = Queue<_TmuxControlCommandRequest>();
  _TmuxControlCommandRequest? _activeControlCommand;
  bool _starting = false;
  bool _disposed = false;
  bool _preserveScheduledReloadThroughSnapshots = false;
  int _restartAttempts = 0;
  DateTime? _lastControlActivity;

  String get _subscriptionName =>
      'flutty-${session.connectionId}-${sessionName.hashCode.abs()}';

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  bool get canRunCommands => !_disposed && _controlSession != null;

  Future<String> runCommand(
    String command, {
    required String commandKind,
    required Duration timeout,
  }) {
    if (_disposed || _controlSession == null) {
      return Future<String>.error(const _TmuxControlCommandUnavailable());
    }
    final request = _TmuxControlCommandRequest(
      command: command,
      commandKind: commandKind,
      timeout: timeout,
    );
    _controlCommandQueue.add(request);
    _startNextControlCommand();
    return request.future;
  }

  void _startNextControlCommand() {
    if (_disposed ||
        _activeControlCommand != null ||
        _controlCommandQueue.isEmpty) {
      return;
    }
    final controlSession = _controlSession;
    if (controlSession == null) {
      _failControlCommands(
        const _TmuxControlCommandUnavailable(),
        StackTrace.current,
      );
      return;
    }
    final request = _controlCommandQueue.removeFirst();
    _activeControlCommand = request;
    request.startTimeout(() {
      if (!identical(_activeControlCommand, request)) {
        return;
      }
      final error = TimeoutException(
        'Timed out waiting for tmux control command',
        request.timeout,
      );
      DiagnosticsLogService.instance.warning(
        'tmux.control',
        'command_timeout',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': request.commandKind,
          'timeoutMs': request.timeout.inMilliseconds,
        },
      );
      _handleControlFailure(error, StackTrace.current);
    });
    DiagnosticsLogService.instance.debug(
      'tmux.control',
      'command_start',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': request.commandKind,
        'queuedCount': _controlCommandQueue.length,
      },
    );
    try {
      controlSession.write(utf8.encode('${request.command}\n'));
    } on Object catch (error, stackTrace) {
      _handleControlFailure(error, stackTrace);
    }
  }

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
          buildTmuxControlModeAttachCommand(
            sessionName,
            extraFlags: extraFlags,
          ),
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
    if (_controlSession == null) return;
    DiagnosticsLogService.instance.debug(
      'tmux.watch',
      'subscribe',
      fields: {'connectionId': session.connectionId},
    );
    runCommand(
      buildTmuxWindowSubscriptionCommand(_subscriptionName),
      commandKind: 'control_subscription',
      timeout: service._execOutputTimeout,
    ).catchError((Object error) {
      if (_disposed) {
        return '';
      }
      DiagnosticsLogService.instance.warning(
        'tmux.watch',
        'subscribe_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return '';
    }).ignore();
  }

  void _handleStdoutLine(String line) {
    if (_disposed) return;
    _lastControlActivity = _now();
    final trimmed = _normalizeTmuxControlLine(line);
    if (_handleControlCommandLine(trimmed)) {
      return;
    }
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
      service._applyCachedWindowEvent(
        session,
        sessionName,
        event,
        extraFlags: extraFlags,
      );
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

  bool _handleControlCommandLine(String trimmed) {
    final request = _activeControlCommand;
    if (request == null) {
      return false;
    }
    if (trimmed.startsWith('%begin ')) {
      request.started = true;
      return true;
    }
    if (!request.started) {
      return false;
    }
    if (trimmed.startsWith('%end ')) {
      _completeActiveControlCommand();
      return true;
    }
    if (trimmed.startsWith('%error ')) {
      _failActiveControlCommand(
        const TmuxCommandException('tmux control command failed'),
        StackTrace.current,
      );
      return true;
    }
    if (trimmed.startsWith('%')) {
      return false;
    }
    request.output.writeln(trimmed);
    return true;
  }

  void _completeActiveControlCommand() {
    final request = _activeControlCommand;
    if (request == null) {
      return;
    }
    _activeControlCommand = null;
    final output = request.output.toString().trimRight();
    DiagnosticsLogService.instance.debug(
      'tmux.control',
      'command_complete',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': request.commandKind,
        'outputChars': output.length,
      },
    );
    request.complete(output);
    _startNextControlCommand();
  }

  void _failActiveControlCommand(Object error, StackTrace stackTrace) {
    final request = _activeControlCommand;
    if (request == null) {
      return;
    }
    _activeControlCommand = null;
    DiagnosticsLogService.instance.warning(
      'tmux.control',
      'command_failed',
      fields: {
        'connectionId': session.connectionId,
        'commandKind': request.commandKind,
        'errorType': error.runtimeType,
      },
    );
    request.completeError(error, stackTrace);
    _startNextControlCommand();
  }

  void _failControlCommands(Object error, StackTrace stackTrace) {
    final activeRequest = _activeControlCommand;
    _activeControlCommand = null;
    if (activeRequest != null) {
      DiagnosticsLogService.instance.warning(
        'tmux.control',
        'command_failed',
        fields: {
          'connectionId': session.connectionId,
          'commandKind': activeRequest.commandKind,
          'errorType': error.runtimeType,
        },
      );
      activeRequest.completeError(error, stackTrace);
    }
    while (_controlCommandQueue.isNotEmpty) {
      _controlCommandQueue.removeFirst().completeError(error, stackTrace);
    }
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
    _cleanupControlSession(error, stackTrace);
    _scheduleRestart(
      channelOpenFailure: shouldBackOffTmuxExecChannelAfterFailure(error),
    );
  }

  void _handleControlClosed() {
    DiagnosticsLogService.instance.info(
      'tmux.watch',
      'control_closed',
      fields: {'connectionId': session.connectionId},
    );
    _cleanupControlSession(
      const TmuxCommandException(
        'tmux control channel closed before command completed',
      ),
      StackTrace.current,
    );
    _scheduleRestart();
  }

  void _scheduleRestart({bool channelOpenFailure = false}) {
    if (_disposed || !_controller.hasListener) return;
    _stopHeartbeat();
    _restartTimer?.cancel();
    final delay = resolveTmuxControlRestartDelay(
      _restartAttempts,
      channelOpenFailure: channelOpenFailure,
    );
    _restartAttempts += 1;
    DiagnosticsLogService.instance.warning(
      'tmux.watch',
      'restart_scheduled',
      fields: {
        'connectionId': session.connectionId,
        'attempt': _restartAttempts,
        'delayMs': delay.inMilliseconds,
        'channelOpenFailure': channelOpenFailure,
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

  void _cleanupControlSession([Object? commandError, StackTrace? stackTrace]) {
    _stopHeartbeat();
    _cancelScheduledReload();
    _failControlCommands(
      commandError ?? const _TmuxControlCommandUnavailable(),
      stackTrace ?? StackTrace.current,
    );
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
