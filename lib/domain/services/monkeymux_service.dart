import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/agent_launch_preset.dart';
import '../models/terminal_backend.dart';
import '../models/terminal_theme.dart';
import '../models/tmux_state.dart';
import 'diagnostics_log_service.dart';
import 'monkeymux_installer_service.dart';
import 'remote_multiplexer_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'tmux_service.dart';

typedef _MonkeyMuxAgentSessionMetadata = ({
  AgentLaunchTool tool,
  String sessionId,
  String? title,
  AgentSessionConfidence confidence,
});

const _oneShotControlResponseTimeout = Duration(seconds: 10);
const _oneShotRunCommandResponseTimeout = Duration(seconds: 25);
const _monkeyMuxSessionStdinCloseTimeout = Duration(milliseconds: 250);

/// MonkeyMux-backed implementation of [RemoteMultiplexerService].
final monkeyMuxServiceProvider = Provider<MonkeyMuxService>(
  (ref) =>
      MonkeyMuxService(installer: ref.watch(monkeyMuxInstallerServiceProvider)),
);

/// How the helper should handle an already-running server with an older
/// version when attaching to a MonkeyMux session.
enum MonkeyMuxServerUpdatePolicy {
  /// Ask on the terminal. Intended for manual helper use only.
  prompt('prompt'),

  /// Keep the current server and suppress terminal prompts.
  never('never'),

  /// Update without a terminal prompt.
  always('always');

  const MonkeyMuxServerUpdatePolicy(this.cliValue);

  /// CLI flag value passed to the MonkeyMux helper.
  final String cliValue;
}

/// Version metadata for an already-running MonkeyMux server.
@immutable
class MonkeyMuxServerStatus {
  /// Creates a running server status snapshot.
  const MonkeyMuxServerStatus({
    required this.version,
    required this.capabilities,
  });

  /// Running helper version reported by the server.
  final String? version;

  /// Capability strings reported by the server.
  final Set<String> capabilities;

  /// Whether the server can be shut down through the control channel.
  bool get supportsShutdown => capabilities.contains('shutdown');

  /// Whether this server differs from the app-bundled helper version.
  bool needsUpdate(String bundledVersion) {
    final runningVersion = version?.trim();
    return runningVersion == null ||
        runningVersion.isEmpty ||
        runningVersion != bundledVersion.trim();
  }
}

/// Builds the foreground attach command for an installed MonkeyMux helper.
String buildMonkeyMuxAttachCommand({
  required String executablePath,
  required String sessionName,
  String? workingDirectory,
  String? launchCommand,
  String? windowName,
  String? terminalThemeReports,
  MonkeyMuxServerUpdatePolicy? serverUpdatePolicy,
  bool startInYoloMode = false,
  bool windows = false,
}) {
  final themeHint = terminalThemeReports?.trim();
  final parts = <String>[
    _monkeyMuxQuoteArg(executablePath, windows: windows),
    'attach',
    if (serverUpdatePolicy != null) ...[
      '--update-policy',
      serverUpdatePolicy.cliValue,
    ],
    if (startInYoloMode) '--restore-yolo',
    if (themeHint != null && themeHint.isNotEmpty) ...[
      '--theme-hint-base64',
      base64Encode(utf8.encode(themeHint)),
    ],
    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) ...[
      '--cwd',
      _monkeyMuxQuoteArg(workingDirectory.trim(), windows: windows),
    ],
    if (windowName != null && windowName.trim().isNotEmpty) ...[
      '--name',
      _monkeyMuxQuoteArg(windowName.trim(), windows: windows),
    ],
    if (launchCommand != null && launchCommand.trim().isNotEmpty) ...[
      '--command',
      _monkeyMuxQuoteArg(launchCommand.trim(), windows: windows),
    ],
    _monkeyMuxQuoteArg(sessionName, windows: windows),
  ];
  return parts.join(' ');
}

/// Controls a remote MonkeyMux session through its JSON backchannel.
class MonkeyMuxService implements RemoteMultiplexerService {
  /// Creates a MonkeyMux service.
  const MonkeyMuxService({
    required MonkeyMuxInstallerService installer,
    Duration agentSessionMetadataPeriodicRefreshInterval = const Duration(
      seconds: 10,
    ),
  }) : _installer = installer,
       _agentSessionMetadataPeriodicRefreshInterval =
           agentSessionMetadataPeriodicRefreshInterval;

  final MonkeyMuxInstallerService _installer;
  final Duration _agentSessionMetadataPeriodicRefreshInterval;

  static final _observers =
      <_MonkeyMuxWatchKey, _MonkeyMuxWindowChangeObserver>{};
  static final _windowSnapshotCache = <_MonkeyMuxWatchKey, List<TmuxWindow>>{};
  static final _windowListRequests =
      <_MonkeyMuxWatchKey, Future<List<TmuxWindow>>>{};
  static final _agentMetadataRequests = <_MonkeyMuxWatchKey, Future<void>>{};
  static final _agentMetadataRequestPanePids = <_MonkeyMuxWatchKey, Set<int>>{};
  static final _agentMetadataPendingWindows =
      <_MonkeyMuxWatchKey, List<TmuxWindow>>{};
  static final _agentMetadataPendingForced = <_MonkeyMuxWatchKey, bool>{};
  static final _agentMetadataRefreshes = <_MonkeyMuxWatchKey, DateTime>{};
  static final _agentMetadataPeriodicTimers = <_MonkeyMuxWatchKey, Timer>{};
  static final _agentMetadataPeriodicSessions =
      <_MonkeyMuxWatchKey, ({SshSession session, String sessionName})>{};
  static final _windowSnapshotGenerations = <_MonkeyMuxWatchKey, int>{};
  static final _appReviewDemoMuxStates =
      <_MonkeyMuxWatchKey, _AppReviewDemoMonkeyMuxState>{};
  static const _agentSessionMetadataFreshTtl = Duration(seconds: 5);

  /// Clears MonkeyMux caches and watchers for a connection.
  Future<void> clearCache(int connectionId) async {
    DiagnosticsLogService.instance.info(
      'monkeymux.cache',
      'clear',
      fields: {'connectionId': connectionId},
    );
    _installer.clearCache(connectionId);
    final demoKeys = _appReviewDemoMuxStates.keys
        .where((key) => key.connectionId == connectionId)
        .toList(growable: false);
    for (final key in demoKeys) {
      _appReviewDemoMuxStates.remove(key)?.dispose();
    }
    _windowSnapshotCache.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    _windowSnapshotGenerations.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    _agentMetadataRefreshes.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    final periodicKeys = _agentMetadataPeriodicTimers.keys
        .where((key) => key.connectionId == connectionId)
        .toList(growable: false);
    for (final key in periodicKeys) {
      _cancelAgentMetadataPeriodicRefresh(key);
    }
    _agentMetadataRequestPanePids.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    _agentMetadataPendingWindows.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    _agentMetadataPendingForced.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    _windowListRequests.removeWhere((key, request) {
      if (key.connectionId == connectionId) {
        request.ignore();
        return true;
      }
      return false;
    });
    _agentMetadataRequests.removeWhere((key, request) {
      if (key.connectionId == connectionId) {
        request.ignore();
        return true;
      }
      return false;
    });
    final observerKeys = _observers.keys
        .where((key) => key.connectionId == connectionId)
        .toList(growable: false);
    for (final key in observerKeys) {
      final observer = _observers.remove(key);
      if (observer != null) {
        await observer.dispose();
      }
    }
  }

  @override
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) {
    final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
    if (isAppReviewDemoSession(session)) {
      final state = _appReviewDemoMuxState(key);
      final windows = state.windows;
      _replaceCachedWindows(key, windows);
      if (state.consumeInitialRender()) {
        _renderAppReviewDemoWindow(session, state.activeWindow);
      }
      return Future<List<TmuxWindow>>.value(windows);
    }
    final existingRequest = _windowListRequests[key];
    if (existingRequest != null) {
      return existingRequest;
    }
    final request = _listWindows(session, sessionName, key);
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
    _MonkeyMuxWatchKey key,
  ) async {
    final response = await _runControlCommand(session, sessionName, {
      'type': 'list_windows',
    });
    _cacheWindows(key, response.windows);
    _scheduleAgentMetadataRefresh(session, sessionName, key, response.windows);
    return _windowSnapshotCache[key] ?? response.windows;
  }

  @override
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) {
    final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
    if (isAppReviewDemoSession(session)) {
      final state = _appReviewDemoMuxState(key);
      scheduleMicrotask(state.emitWindowList);
      return state.stream;
    }
    final observer = _observers.putIfAbsent(
      key,
      () => _MonkeyMuxWindowChangeObserver(
        session: session,
        sessionName: sessionName,
        installer: _installer,
        onWindowList: (windows) {
          _cacheWindows(key, windows);
          _scheduleAgentMetadataRefresh(session, sessionName, key, windows);
        },
        onWindowSnapshot: (window) {
          final cachedWindows = _windowSnapshotCache[key];
          final forceAgentMetadataRefresh =
              shouldForceAgentSessionMetadataRefreshForSnapshot(
                cachedWindows ?? const <TmuxWindow>[],
                window,
              );
          _cacheWindowSnapshot(key, window);
          final windows = _windowSnapshotCache[key];
          if (windows != null) {
            _scheduleAgentMetadataRefresh(
              session,
              sessionName,
              key,
              windows,
              force: forceAgentMetadataRefresh,
            );
          }
        },
        onDispose: () {
          _observers.remove(key);
          _cancelAgentMetadataPeriodicRefresh(key);
        },
      ),
    );
    final cachedWindows = _windowSnapshotCache[key];
    if (cachedWindows != null) {
      _scheduleAgentMetadataRefresh(session, sessionName, key, cachedWindows);
    }
    DiagnosticsLogService.instance.info(
      'monkeymux.watch',
      'watch_requested',
      fields: {
        'connectionId': session.connectionId,
        'observerCount': _observers.length,
      },
    );
    return observer.stream;
  }

  @override
  Future<TmuxPaneContext?> currentPaneContext(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      final active = _appReviewDemoMuxState(
        _MonkeyMuxWatchKey(session.connectionId, sessionName),
      ).activeWindow;
      return TmuxPaneContext(
        currentPath: active.currentPath,
        currentCommand: active.currentCommand,
      );
    }
    final response = await _runControlCommand(session, sessionName, {
      'type': 'query_active_context',
    }, priority: priority);
    return TmuxPaneContext(
      currentPath: _nonEmpty(response.currentPath),
      currentCommand: _nonEmpty(response.currentCommand),
    );
  }

  @override
  Future<String?> currentPanePath(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) async => (await currentPaneContext(
    session,
    sessionName,
    priority: priority,
    extraFlags: extraFlags,
  ))?.currentPath;

  @override
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
    String? workingDirectory,
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
      final state = _appReviewDemoMuxState(key);
      final window = state.createWindow(
        command: command,
        name: name,
        workingDirectory: workingDirectory,
      );
      _replaceCachedWindows(key, state.windows);
      _renderAppReviewDemoWindow(session, window);
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'create_window',
      if (command != null && command.trim().isNotEmpty)
        'command': command.trim(),
      if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      if (workingDirectory != null && workingDirectory.trim().isNotEmpty)
        'cwd': workingDirectory.trim(),
    });
  }

  @override
  Future<void> selectWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
    Map<int, int>? clientImageSignatures,
  }) async {
    if (isAppReviewDemoSession(session)) {
      final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
      final state = _appReviewDemoMuxState(key);
      final window = state.selectWindow(windowIndex, windowId: windowId);
      _replaceCachedWindows(key, state.windows);
      _renderAppReviewDemoWindow(session, window);
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'select_window',
      if (windowId != null && windowId.trim().isNotEmpty)
        'windowId': windowId.trim()
      else
        'windowIndex': windowIndex,
      if (clientImageSignatures != null && clientImageSignatures.isNotEmpty)
        'haveImageSignatures': {
          for (final entry in clientImageSignatures.entries)
            entry.key.toString(): entry.value,
        },
    });
  }

  /// Asks the server to replay specific retained Kitty image transmissions the
  /// client is missing for the active window.
  ///
  /// After a window switch or reconnect, the bounded image replay can omit
  /// images the foreground app still shows (it draws placeholder cells that
  /// reference them but never re-transmits the bytes). The client detects those
  /// unresolved ids and calls this so the server replays exactly them from its
  /// per-window retained cache. Best-effort: a failure (e.g. an older server
  /// without this command) is logged and swallowed so image gaps never break
  /// the session.
  Future<void> requestImages(
    SshSession session,
    String sessionName,
    Iterable<int> imageIds,
  ) async {
    if (isAppReviewDemoSession(session)) {
      return;
    }
    final ids = <String>[
      for (final id in imageIds)
        if (id > 0) id.toString(),
    ];
    if (ids.isEmpty) {
      return;
    }
    try {
      await _runControlCommand(session, sessionName, {
        'type': 'request_images',
        'imageIds': ids,
      }, priority: SshExecPriority.low);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.graphics',
        'request_images_failed',
        fields: {
          'connectionId': session.connectionId,
          'count': ids.length,
          'errorType': error.runtimeType.toString(),
        },
      );
    }
  }

  @override
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
      final state = _appReviewDemoMuxState(key);
      final closed = state.killWindow(windowIndex);
      _replaceCachedWindows(key, state.windows);
      if (closed != null) {
        _renderAppReviewDemoWindow(session, state.activeWindow);
      }
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'close_window',
      'windowIndex': windowIndex,
    });
  }

  @override
  bool isExecChannelCoolingDown(SshSession session) => false;

  /// Whether commands for [sessionName] can be sent over an already-open
  /// MonkeyMux control channel.
  ///
  /// When this is true, high-frequency resize updates do not open a new SSH exec
  /// channel per event and can follow pinch-zoom in real time. When false, the
  /// UI should throttle resize syncs to avoid flooding the SSH connection with
  /// one-shot exec channels.
  bool hasLiveControlChannel(SshSession session, String sessionName) =>
      isAppReviewDemoSession(session) ||
      (_observers[_MonkeyMuxWatchKey(session.connectionId, sessionName)]
              ?.isControlChannelReady ??
          false);

  @override
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return true;
    }
    final response = await _runControlCommand(session, sessionName, {
      'type': 'query_attach_state',
    });
    return response.hasForegroundClient;
  }

  @override
  Future<String?> foregroundSessionNameOrThrow(
    SshSession session, {
    String? extraFlags,
  }) async => null;

  @override
  Future<void> refreshTerminalTheme(
    SshSession session,
    String sessionName,
    TerminalThemeData theme, {
    String? extraFlags,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'theme_changed',
      'data': buildTerminalThemeHintReports(theme),
    }, priority: SshExecPriority.low);
  }

  /// Resizes the active MonkeyMux PTY to match the visible terminal.
  Future<void> resizeTerminal(
    SshSession session,
    String sessionName, {
    required int columns,
    required int rows,
    bool redraw = false,
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return;
    }
    await _runControlCommand(session, sessionName, {
      'type': 'resize',
      'width': columns,
      'height': rows,
      if (redraw) 'redraw': true,
    }, priority: priority);
  }

  /// Runs a short-lived command through the MonkeyMux control client.
  Future<TerminalClientCommandResult> runClientCommand(
    SshSession session,
    String sessionName,
    String command, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (isAppReviewDemoSession(session)) {
      return TerminalClientCommandResult(
        output: 'demo command completed: $command\n',
        exitCode: 0,
      );
    }
    final response = await _runControlCommand(session, sessionName, {
      'type': 'run_command',
      'command': command,
    }, priority: priority);
    return TerminalClientCommandResult(
      output: response.data ?? '',
      exitCode: response.exitCode,
    );
  }

  /// Returns metadata for an already-running MonkeyMux server, if any.
  Future<MonkeyMuxServerStatus?> runningServerStatus(
    SshSession session,
    MonkeyMuxInstallation installation,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    final controlCommand = _buildMonkeyMuxControlCommand(
      installation,
      sessionName,
    );
    try {
      return await session.runQueuedExec(
        () => _readRunningServerStatus(session, controlCommand),
        priority: priority,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.status',
        'unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  /// Returns running server status using any already-installed helper version.
  Future<MonkeyMuxServerStatus?> runningServerStatusFromInstalledHelpers(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (session.remoteIsWindows) {
      // This best-effort pre-install probe relies on a POSIX shell glob loop
      // that Windows shells cannot evaluate. Skip it; the version-specific
      // status probe (runningServerStatus) runs after install with the correct
      // Windows quoting, and `attach` still negotiates version mismatches.
      return null;
    }
    final command =
        r'for helper in "$HOME"/.monkeyssh/bin/monkeymux/*/*/monkeymux; do '
        r'[ -x "$helper" ] || continue; '
        r'"$helper" control --json '
        '${_shellQuote(sessionName)}'
        ' 2>/dev/null && exit 0; done; exit 1';
    try {
      return await session.runQueuedExec(
        () => _readRunningServerStatus(session, command),
        priority: priority,
      );
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.status',
        'installed_helper_unavailable',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  Future<_MonkeyMuxControlResponse> _runControlCommand(
    SshSession session,
    String sessionName,
    Map<String, Object?> command, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    final observer =
        _observers[_MonkeyMuxWatchKey(session.connectionId, sessionName)];
    if (observer != null) {
      return observer.runCommand(command, priority: priority);
    }
    final installation = await _installer.ensureInstalled(
      session,
      priority: priority,
    );
    final controlCommand = _buildMonkeyMuxControlCommand(
      installation,
      sessionName,
    );
    final commandId = DateTime.now().microsecondsSinceEpoch.toString();
    final request = <String, Object?>{'id': commandId, ...command};
    return session.runQueuedExec(
      () => _runOneShotControlCommand(session, controlCommand, request),
      priority: priority,
    );
  }

  Future<
    ({
      Map<int, _MonkeyMuxAgentSessionMetadata> metadataByPanePid,
      Set<int> panePids,
    })?
  >
  _loadAgentMetadata(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
    Set<int> panePids,
  ) async {
    if (panePids.isEmpty) {
      return null;
    }

    try {
      DiagnosticsLogService.instance.debug(
        'monkeymux.agent',
        'active_session_metadata_start',
        fields: {
          'connectionId': session.connectionId,
          'paneCount': panePids.length,
        },
      );
      final response = await _runControlCommand(session, sessionName, {
        'type': 'run_command',
        'command': buildAgentActiveSessionMetadataCommand(panePids),
      }, priority: SshExecPriority.low);
      final metadataByPanePid = parseAgentActiveSessionMetadataOutput(
        response.data ?? '',
        panePids,
      );
      _agentMetadataRefreshes[key] = DateTime.now();
      DiagnosticsLogService.instance.info(
        'monkeymux.agent',
        'active_session_metadata_complete',
        fields: {
          'connectionId': session.connectionId,
          'paneCount': panePids.length,
          'matchCount': metadataByPanePid.length,
        },
      );
      return (metadataByPanePid: metadataByPanePid, panePids: panePids);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.agent',
        'active_session_metadata_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return null;
    }
  }

  void _scheduleAgentMetadataRefresh(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
    List<TmuxWindow> windows, {
    bool force = false,
  }) {
    final panePids = _monkeyMuxAgentPanePids(windows);
    if (panePids.isEmpty) {
      _cancelAgentMetadataPeriodicRefresh(key);
      return;
    }
    final observer = _observers[key];
    if (observer != null) {
      if (!observer.isControlChannelReady) {
        return;
      }
      _ensureAgentMetadataPeriodicRefresh(session, sessionName, key);
    }
    if (_agentMetadataRequests.containsKey(key)) {
      final activePanePids =
          _agentMetadataRequestPanePids[key] ?? const <int>{};
      final hasNewPanePids = panePids.any(
        (panePid) => !activePanePids.contains(panePid),
      );
      if (force || hasNewPanePids) {
        _agentMetadataPendingWindows[key] = windows;
        _agentMetadataPendingForced[key] =
            (_agentMetadataPendingForced[key] ?? false) ||
            force ||
            hasNewPanePids;
      }
      return;
    }
    final lastRefresh = _agentMetadataRefreshes[key];
    if (!force &&
        lastRefresh != null &&
        DateTime.now().difference(lastRefresh) <
            _agentSessionMetadataFreshTtl) {
      return;
    }
    _agentMetadataRequestPanePids[key] = panePids;
    late final Future<void> request;
    request = _loadAgentMetadata(session, sessionName, key, panePids).then((
      metadataRefresh,
    ) {
      if (!identical(_agentMetadataRequests[key], request)) {
        return;
      }
      if (metadataRefresh == null) {
        return;
      }
      final previousWindows = _windowSnapshotCache[key] ?? windows;
      final result = _applyMonkeyMuxAgentSessionMetadata(
        previousWindows,
        metadataRefresh.metadataByPanePid,
        refreshedPanePids: metadataRefresh.panePids,
      );
      if (!result.changed) return;
      _replaceCachedWindows(key, result.windows);
      _observers[key]?.emitWindowList(
        _windowSnapshotCache[key] ?? result.windows,
      );
    });
    _agentMetadataRequests[key] = request;
    request.whenComplete(() {
      if (!identical(_agentMetadataRequests[key], request)) {
        return;
      }
      _agentMetadataRequests.remove(key);
      _agentMetadataRequestPanePids.remove(key);
      final pendingWindows = _agentMetadataPendingWindows.remove(key);
      final pendingForced = _agentMetadataPendingForced.remove(key) ?? false;
      if (pendingWindows != null && pendingWindows.isNotEmpty) {
        _scheduleAgentMetadataRefresh(
          session,
          sessionName,
          key,
          pendingWindows,
          force: pendingForced,
        );
      }
    }).ignore();
  }

  void _ensureAgentMetadataPeriodicRefresh(
    SshSession session,
    String sessionName,
    _MonkeyMuxWatchKey key,
  ) {
    if (_agentSessionMetadataPeriodicRefreshInterval <= Duration.zero) {
      return;
    }
    _agentMetadataPeriodicSessions[key] = (
      session: session,
      sessionName: sessionName,
    );
    if (_agentMetadataPeriodicTimers.containsKey(key)) {
      return;
    }
    _agentMetadataPeriodicTimers[key] = Timer(
      _agentSessionMetadataPeriodicRefreshInterval,
      () {
        _agentMetadataPeriodicTimers.remove(key);
        final refreshContext = _agentMetadataPeriodicSessions[key];
        if (refreshContext == null) {
          return;
        }
        if (!_observers.containsKey(key)) {
          _agentMetadataPeriodicSessions.remove(key);
          return;
        }
        final windows = _windowSnapshotCache[key];
        if (windows == null || _monkeyMuxAgentPanePids(windows).isEmpty) {
          _agentMetadataPeriodicSessions.remove(key);
          return;
        }
        _scheduleAgentMetadataRefresh(
          refreshContext.session,
          refreshContext.sessionName,
          key,
          windows,
          force: true,
        );
      },
    );
  }

  static void _cancelAgentMetadataPeriodicRefresh(_MonkeyMuxWatchKey key) {
    _agentMetadataPeriodicTimers.remove(key)?.cancel();
    _agentMetadataPeriodicSessions.remove(key);
  }

  static void _cacheWindows(_MonkeyMuxWatchKey key, List<TmuxWindow> windows) {
    if (windows.isEmpty) {
      _windowSnapshotCache[key] = const <TmuxWindow>[];
      _bumpWindowSnapshotGeneration(key);
      return;
    }
    final currentWindows = _windowSnapshotCache[key];
    _windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable(
      currentWindows == null
          ? windows
          : applyTmuxWindowChangeEvent(
              currentWindows,
              TmuxWindowListEvent(windows),
            ),
    );
    _bumpWindowSnapshotGeneration(key);
  }

  static void _cacheWindowSnapshot(_MonkeyMuxWatchKey key, TmuxWindow window) {
    final currentWindows = _windowSnapshotCache[key];
    if (currentWindows == null || currentWindows.isEmpty) {
      _windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable([window]);
      _bumpWindowSnapshotGeneration(key);
      return;
    }
    _windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable(
      applyTmuxWindowChangeEvent(
        currentWindows,
        TmuxWindowSnapshotEvent(window),
      ),
    );
    _bumpWindowSnapshotGeneration(key);
  }

  static void _replaceCachedWindows(
    _MonkeyMuxWatchKey key,
    List<TmuxWindow> windows,
  ) {
    _windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable(windows);
    _bumpWindowSnapshotGeneration(key);
  }

  static void _bumpWindowSnapshotGeneration(_MonkeyMuxWatchKey key) {
    _windowSnapshotGenerations.update(
      key,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
  }
}

({List<TmuxWindow> windows, bool changed}) _applyMonkeyMuxAgentSessionMetadata(
  List<TmuxWindow> windows,
  Map<int, _MonkeyMuxAgentSessionMetadata> metadataByPanePid, {
  Set<int>? refreshedPanePids,
}) {
  var changed = false;
  final enriched = windows
      .map((window) {
        final panePid = window.panePid;
        final metadata = panePid == null ? null : metadataByPanePid[panePid];
        if (metadata == null || metadata.tool != window.foregroundAgentTool) {
          return window;
        }
        if (window.activeAgentSessionId == metadata.sessionId &&
            window.agentSessionTitle == metadata.title &&
            window.activeAgentSessionConfidence == metadata.confidence) {
          return window;
        }
        changed = true;
        return window.copyWith(
          activeAgentSessionId: metadata.sessionId,
          agentSessionTitle: metadata.title,
          activeAgentSessionConfidence: metadata.confidence,
        );
      })
      .toList(growable: false);
  return (windows: changed ? enriched : windows, changed: changed);
}

/// Applies live Copilot metadata to MonkeyMux windows for regression tests.
@visibleForTesting
List<TmuxWindow> applyMonkeyMuxAgentSessionMetadataForTesting(
  List<TmuxWindow> windows,
  Map<int, ({String sessionId, String? title})> metadataByPanePid, {
  Set<int>? refreshedPanePids,
}) {
  final agentMetadataByPanePid = <int, _MonkeyMuxAgentSessionMetadata>{
    for (final entry in metadataByPanePid.entries)
      entry.key: (
        tool: AgentLaunchTool.copilotCli,
        sessionId: entry.value.sessionId,
        title: entry.value.title,
        confidence: AgentSessionConfidence.medium,
      ),
  };
  return _applyMonkeyMuxAgentSessionMetadata(
    windows,
    agentMetadataByPanePid,
    refreshedPanePids: refreshedPanePids,
  ).windows;
}

Future<_MonkeyMuxControlResponse> _runOneShotControlCommand(
  SshSession session,
  String command,
  Map<String, Object?> request,
) async {
  final execSession = await session.execute(command);
  try {
    execSession.stderr.drain<void>().ignore();
    final requestId = request['id'] as String?;
    execSession.write(utf8.encode('${jsonEncode(request)}\n'));
    final responseTimeout = _oneShotResponseTimeout(request);
    await for (final line
        in execSession.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(responseTimeout)) {
      final response = _MonkeyMuxControlResponse.tryParse(line);
      if (response == null || response.id != requestId) {
        continue;
      }
      if (response.isError) {
        throw MonkeyMuxInstallException(response.error ?? 'MonkeyMux failed.');
      }
      return response;
    }
  } finally {
    await _closeMonkeyMuxExecSession(
      execSession,
      ownerSession: session,
      operation: 'one_shot_control',
    );
  }
  throw const MonkeyMuxInstallException(
    'MonkeyMux control command closed without a response.',
  );
}

Duration _oneShotResponseTimeout(Map<String, Object?> request) =>
    request['type'] == 'run_command'
    ? _oneShotRunCommandResponseTimeout
    : _oneShotControlResponseTimeout;

Future<MonkeyMuxServerStatus?> _readRunningServerStatus(
  SshSession session,
  String command,
) async {
  final execSession = await session.execute(command);
  try {
    execSession.stderr.drain<void>().ignore();
    await for (final line
        in execSession.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(const Duration(seconds: 5))) {
      final response = _MonkeyMuxControlResponse.tryParse(line);
      if (response == null || response.type != 'hello') {
        continue;
      }
      return MonkeyMuxServerStatus(
        version: response.version,
        capabilities: response.capabilities.toSet(),
      );
    }
  } on TimeoutException {
    return null;
  } finally {
    await _closeMonkeyMuxExecSession(
      execSession,
      ownerSession: session,
      operation: 'server_status',
    );
  }
  return null;
}

Future<void> _closeMonkeyMuxExecSession(
  SSHSession execSession, {
  required SshSession ownerSession,
  required String operation,
}) => _closeMonkeyMuxSession(
  execSession,
  connectionId: ownerSession.connectionId,
  category: 'monkeymux.control',
  operation: operation,
);

Future<void> _closeMonkeyMuxSession(
  SSHSession session, {
  required int connectionId,
  required String category,
  required String operation,
}) async {
  try {
    await session.stdin.close().timeout(_monkeyMuxSessionStdinCloseTimeout);
  } on TimeoutException {
    DiagnosticsLogService.instance.warning(
      category,
      'stdin_close_timed_out',
      fields: {'connectionId': connectionId, 'operation': operation},
    );
  } on Object catch (error) {
    DiagnosticsLogService.instance.warning(
      category,
      'stdin_close_failed',
      fields: {
        'connectionId': connectionId,
        'operation': operation,
        'errorType': error.runtimeType,
      },
    );
  }

  _closeSshSessionBestEffort(
    session,
    connectionId: connectionId,
    category: category,
    operation: operation,
  );
}

void _closeSshSessionBestEffort(
  SSHSession session, {
  required int connectionId,
  required String category,
  required String operation,
}) {
  void logFailure(Object error) {
    DiagnosticsLogService.instance.warning(
      category,
      'session_close_failed',
      fields: {
        'connectionId': connectionId,
        'operation': operation,
        'errorType': error.runtimeType,
      },
    );
  }

  runZonedGuarded(session.close, (error, _) => logFailure(error));
}

class _MonkeyMuxWindowChangeObserver {
  _MonkeyMuxWindowChangeObserver({
    required this.session,
    required this.sessionName,
    required this.installer,
    required this.onWindowList,
    required this.onWindowSnapshot,
    required this.onDispose,
  }) : _controller = StreamController<TmuxWindowChangeEvent>.broadcast() {
    _controller
      ..onListen = _ensureStarted
      ..onCancel = () => unawaited(dispose());
  }

  final SshSession session;
  final String sessionName;
  final MonkeyMuxInstallerService installer;
  final ValueChanged<List<TmuxWindow>> onWindowList;
  final ValueChanged<TmuxWindow> onWindowSnapshot;
  final VoidCallback onDispose;
  final StreamController<TmuxWindowChangeEvent> _controller;
  final _normalCommandQueue = Queue<_MonkeyMuxControlRequest>();
  final _lowCommandQueue = Queue<_MonkeyMuxControlRequest>();
  final _pendingCommands = <String, _MonkeyMuxControlRequest>{};

  SSHSession? _controlSession;
  Timer? _reconnectTimer;
  // Cancelled in _cleanup().
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _stdoutSubscription;
  // Cancelled in _cleanup().
  // ignore: cancel_subscriptions
  StreamSubscription<void>? _doneSubscription;
  Future<void>? _startFuture;
  Future<void>? _disposeFuture;
  MonkeyMuxInstallation? _installation;
  bool _disposed = false;
  int _reconnectAttempts = 0;

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  bool get isControlChannelReady =>
      !_disposed && !_controller.isClosed && _controlSession != null;

  void emitWindowList(List<TmuxWindow> windows) {
    if (_disposed || _controller.isClosed || windows.isEmpty) {
      return;
    }
    onWindowList(windows);
    _controller.add(TmuxWindowListEvent(windows));
  }

  Future<_MonkeyMuxControlResponse> runCommand(
    Map<String, Object?> command, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    if (_disposed) {
      throw const MonkeyMuxInstallException(
        'MonkeyMux control channel unavailable.',
      );
    }
    await _ensureStarted();
    if (_disposed || _controlSession == null) {
      throw const MonkeyMuxInstallException(
        'MonkeyMux control channel unavailable.',
      );
    }
    final request = _MonkeyMuxControlRequest(command);
    switch (priority) {
      case SshExecPriority.normal:
        _normalCommandQueue.add(request);
      case SshExecPriority.low:
        _lowCommandQueue.add(request);
    }
    _drainCommands();
    return request.future;
  }

  Future<void> _ensureStarted() {
    if (_disposed || _controlSession != null) return Future<void>.value();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final existingStart = _startFuture;
    if (existingStart != null) return existingStart;
    final start = _start();
    _startFuture = start;
    unawaited(
      start.whenComplete(() {
        if (identical(_startFuture, start)) {
          _startFuture = null;
        }
      }),
    );
    return start;
  }

  Future<void> _start() async {
    try {
      final installation = _installation ??= await installer.ensureInstalled(
        session,
      );
      if (_disposed) return;
      final command = _buildMonkeyMuxControlCommand(installation, sessionName);
      final controlSession = await session.execute(command);
      if (_disposed) {
        await _closeControlSession(controlSession, operation: 'start_disposed');
        return;
      }
      _controlSession = controlSession;
      controlSession.stderr.drain<void>().ignore();
      _stdoutSubscription = controlSession.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine, onError: _handleError);
      _doneSubscription = controlSession.done.asStream().listen(
        (_) => _handleClosed(),
        onError: _handleError,
      );
      _reconnectAttempts = 0;
      _drainCommands();
      DiagnosticsLogService.instance.info(
        'monkeymux.watch',
        'started',
        fields: {'connectionId': session.connectionId},
      );
    } on Object catch (error, stackTrace) {
      _handleError(error, stackTrace);
    }
  }

  void _drainCommands() {
    final controlSession = _controlSession;
    if (controlSession == null) return;
    while (_normalCommandQueue.isNotEmpty || _lowCommandQueue.isNotEmpty) {
      final request = _normalCommandQueue.isNotEmpty
          ? _normalCommandQueue.removeFirst()
          : _lowCommandQueue.removeFirst();
      _pendingCommands[request.id] = request;
      try {
        controlSession.write(utf8.encode('${jsonEncode(request.payload)}\n'));
      } on Object catch (error, stackTrace) {
        _pendingCommands.remove(request.id);
        _handleError(error, stackTrace);
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  void _handleLine(String line) {
    if (_disposed) return;
    final response = _MonkeyMuxControlResponse.tryParse(line);
    if (response == null) return;
    final pendingCommand = _pendingCommands.remove(response.id);
    if (pendingCommand != null) {
      if (response.isError) {
        pendingCommand.completeError(
          MonkeyMuxInstallException(response.error ?? 'MonkeyMux failed.'),
          StackTrace.current,
        );
      } else {
        pendingCommand.complete(response);
      }
      return;
    }
    switch (response.type) {
      case 'window_updated':
      case 'window_added':
        final window = response.window;
        if (window != null && !_controller.isClosed) {
          onWindowSnapshot(window);
          _controller.add(TmuxWindowSnapshotEvent(window));
        }
      case 'window_list':
      case 'active_window_changed':
        onWindowList(response.windows);
        if (!_controller.isClosed) {
          _controller.add(TmuxWindowListEvent(response.windows));
        }
      case 'window_removed':
        if (!_controller.isClosed) {
          _controller.add(const TmuxWindowReloadEvent());
        }
    }
  }

  void _handleError(Object error, StackTrace stackTrace) {
    if (_disposed) return;
    DiagnosticsLogService.instance.warning(
      'monkeymux.watch',
      'failed',
      fields: {
        'connectionId': session.connectionId,
        'errorType': error.runtimeType,
      },
    );
    _failPending(error, stackTrace);
    unawaited(_cleanup().whenComplete(_scheduleReconnect));
  }

  void _handleClosed() {
    if (_disposed) return;
    _failPending(
      const MonkeyMuxInstallException('MonkeyMux control channel closed.'),
      StackTrace.current,
    );
    unawaited(_cleanup().whenComplete(_scheduleReconnect));
  }

  void _failPending(Object error, StackTrace stackTrace) {
    while (_normalCommandQueue.isNotEmpty) {
      _normalCommandQueue.removeFirst().completeError(error, stackTrace);
    }
    while (_lowCommandQueue.isNotEmpty) {
      _lowCommandQueue.removeFirst().completeError(error, stackTrace);
    }
    for (final request in _pendingCommands.values) {
      request.completeError(error, stackTrace);
    }
    _pendingCommands.clear();
  }

  Future<void> _cleanup() async {
    final stdoutSubscription = _stdoutSubscription;
    final doneSubscription = _doneSubscription;
    final controlSession = _controlSession;
    _stdoutSubscription = null;
    _doneSubscription = null;
    _controlSession = null;
    await Future.wait([
      if (stdoutSubscription != null) stdoutSubscription.cancel(),
      if (doneSubscription != null) doneSubscription.cancel(),
    ]);
    if (controlSession != null) {
      await _closeControlSession(controlSession, operation: 'observer_cleanup');
    }
  }

  Future<void> _closeControlSession(
    SSHSession controlSession, {
    required String operation,
  }) => _closeMonkeyMuxSession(
    controlSession,
    connectionId: session.connectionId,
    category: 'monkeymux.watch',
    operation: operation,
  );

  void _scheduleReconnect() {
    if (_disposed ||
        _controller.isClosed ||
        !_controller.hasListener ||
        _controlSession != null ||
        _startFuture != null ||
        _reconnectTimer != null) {
      return;
    }
    final delay = _nextReconnectDelay();
    _reconnectAttempts += 1;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_disposed || _controller.isClosed || !_controller.hasListener) {
        return;
      }
      unawaited(_ensureStarted());
    });
  }

  Duration _nextReconnectDelay() {
    const baseDelay = Duration(milliseconds: 250);
    const maxDelay = Duration(seconds: 5);
    var factor = 1;
    for (var i = 0; i < _reconnectAttempts && factor < 16; i += 1) {
      factor *= 2;
    }
    final milliseconds = baseDelay.inMilliseconds * factor;
    if (milliseconds >= maxDelay.inMilliseconds) {
      return maxDelay;
    }
    return Duration(milliseconds: milliseconds);
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _cleanup();
    if (!_controller.isClosed) {
      await _controller.close();
    }
    onDispose();
  }
}

class _MonkeyMuxControlRequest {
  _MonkeyMuxControlRequest(Map<String, Object?> command)
    : this._(DateTime.now().microsecondsSinceEpoch.toString(), command);

  _MonkeyMuxControlRequest._(this.id, Map<String, Object?> command)
    : payload = {'id': id, ...command};

  final String id;
  final Map<String, Object?> payload;
  final _completer = Completer<_MonkeyMuxControlResponse>();

  Future<_MonkeyMuxControlResponse> get future => _completer.future;

  void complete(_MonkeyMuxControlResponse response) {
    if (!_completer.isCompleted) {
      _completer.complete(response);
    }
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) {
      _completer.completeError(error, stackTrace);
    }
  }
}

class _MonkeyMuxControlResponse {
  const _MonkeyMuxControlResponse({
    required this.type,
    required this.status,
    this.id,
    this.error,
    this.window,
    this.windows = const [],
    this.currentPath,
    this.currentCommand,
    this.data,
    this.exitCode,
    this.version,
    this.capabilities = const [],
    this.hasForegroundClient = false,
  });

  factory _MonkeyMuxControlResponse.fromJson(Map<String, Object?> json) =>
      _MonkeyMuxControlResponse(
        id: json['id'] as String?,
        type: json['type'] as String? ?? '',
        status: json['status'] as String? ?? '',
        error: json['error'] as String?,
        window: _windowFromJson(json['window']),
        windows: switch (json['windows']) {
          final List<Object?> windows =>
            windows
                .map(_windowFromJson)
                .whereType<TmuxWindow>()
                .toList(growable: false),
          _ => const <TmuxWindow>[],
        },
        currentPath: json['currentPath'] as String?,
        currentCommand: json['currentCommand'] as String?,
        data: json['data'] as String?,
        exitCode: json['exitCode'] as int?,
        version: json['version'] as String?,
        capabilities: switch (json['capabilities']) {
          final List<Object?> capabilities =>
            capabilities.whereType<String>().toList(growable: false),
          _ => const <String>[],
        },
        hasForegroundClient: json['hasForegroundClient'] == true,
      );

  static _MonkeyMuxControlResponse? tryParse(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      return _MonkeyMuxControlResponse.fromJson(decoded);
    } on FormatException {
      return null;
    }
  }

  final String? id;
  final String type;
  final String status;
  final String? error;
  final TmuxWindow? window;
  final List<TmuxWindow> windows;
  final String? currentPath;
  final String? currentCommand;
  final String? data;
  final int? exitCode;
  final String? version;
  final List<String> capabilities;
  final bool hasForegroundClient;

  bool get isError => status == 'error' || type == 'error';
}

@immutable
class _MonkeyMuxWatchKey {
  const _MonkeyMuxWatchKey(this.connectionId, this.sessionName);

  final int connectionId;
  final String sessionName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _MonkeyMuxWatchKey &&
          connectionId == other.connectionId &&
          sessionName == other.sessionName;

  @override
  int get hashCode => Object.hash(connectionId, sessionName);
}

_AppReviewDemoMonkeyMuxState _appReviewDemoMuxState(_MonkeyMuxWatchKey key) =>
    MonkeyMuxService._appReviewDemoMuxStates.putIfAbsent(
      key,
      _AppReviewDemoMonkeyMuxState.new,
    );

class _AppReviewDemoMonkeyMuxState {
  _AppReviewDemoMonkeyMuxState()
    : _windows = List<_AppReviewDemoWindowSpec>.of(_initialWindows());

  static const _workspace = '/home/reviewer/work/monkeyssh-demo';

  final _controller = StreamController<TmuxWindowChangeEvent>.broadcast();
  final List<_AppReviewDemoWindowSpec> _windows;
  int _activeIndex = 0;
  int _nextId = 10;
  bool _renderedInitial = false;

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  TmuxWindow get activeWindow => windows.firstWhere(
    (window) => window.isActive,
    orElse: () => windows.first,
  );

  List<TmuxWindow> get windows => [
    for (var index = 0; index < _windows.length; index += 1)
      _windows[index].toWindow(index: index, isActive: index == _activeIndex),
  ];

  bool consumeInitialRender() {
    if (_renderedInitial) {
      return false;
    }
    _renderedInitial = true;
    return true;
  }

  TmuxWindow createWindow({
    String? command,
    String? name,
    String? workingDirectory,
  }) {
    final tool =
        agentLaunchToolForCommandText(command) ??
        agentLaunchToolForCommandText(name);
    final id = _nextId++;
    final windowName =
        _nonEmpty(name) ??
        tool?.label ??
        _nonEmpty(command)?.split(RegExp(r'\s+')).first ??
        'shell $id';
    final spec = _AppReviewDemoWindowSpec(
      id: '@$id',
      panePid: 7300 + id,
      name: windowName,
      currentCommand: tool?.commandName ?? _nonEmpty(command) ?? 'zsh',
      currentPath: _nonEmpty(workingDirectory) ?? _workspace,
      paneTitle: tool == null ? windowName : '${tool.label} · demo window',
      agentTool: tool,
      agentSessionTitle: tool == null ? null : 'Demo ${tool.label} session',
    );
    _windows.add(spec);
    _activeIndex = _windows.length - 1;
    emitWindowList();
    return spec.toWindow(index: _activeIndex, isActive: true);
  }

  TmuxWindow selectWindow(int windowIndex, {String? windowId}) {
    final targetIndex = windowId == null
        ? windowIndex
        : _windows.indexWhere((window) => window.id == windowId);
    if (targetIndex >= 0 && targetIndex < _windows.length) {
      _activeIndex = targetIndex;
    }
    emitWindowList();
    return activeWindow;
  }

  TmuxWindow? killWindow(int windowIndex) {
    if (_windows.length <= 1 ||
        windowIndex < 0 ||
        windowIndex >= _windows.length) {
      return null;
    }
    final closed = _windows.removeAt(windowIndex);
    if (_activeIndex >= _windows.length) {
      _activeIndex = _windows.length - 1;
    } else if (windowIndex < _activeIndex) {
      _activeIndex -= 1;
    }
    emitWindowList();
    return closed.toWindow(index: windowIndex, isActive: false);
  }

  void emitWindowList() {
    if (!_controller.isClosed) {
      _controller.add(TmuxWindowListEvent(windows));
    }
  }

  void dispose() {
    if (!_controller.isClosed) {
      unawaited(_controller.close());
    }
  }

  static List<_AppReviewDemoWindowSpec> _initialWindows() => const [
    _AppReviewDemoWindowSpec(
      id: '@0',
      panePid: 7300,
      name: 'Copilot CLI',
      currentCommand: 'copilot',
      currentPath: _workspace,
      paneTitle: 'Copilot CLI · planning review notes',
      agentTool: AgentLaunchTool.copilotCli,
      agentSessionTitle: 'Planning review notes',
    ),
    _AppReviewDemoWindowSpec(
      id: '@1',
      panePid: 7301,
      name: 'Claude Code',
      currentCommand: 'claude',
      currentPath: _workspace,
      paneTitle: 'Claude Code · running tests',
      agentTool: AgentLaunchTool.claudeCode,
      agentSessionTitle: 'Running focused tests',
    ),
    _AppReviewDemoWindowSpec(
      id: '@2',
      panePid: 7302,
      name: 'OpenCode',
      currentCommand: 'opencode',
      currentPath: '$_workspace/src',
      paneTitle: 'OpenCode · editing README.md',
      agentTool: AgentLaunchTool.openCode,
      agentSessionTitle: 'Editing README.md',
    ),
    _AppReviewDemoWindowSpec(
      id: '@3',
      panePid: 7303,
      name: 'SFTP',
      currentCommand: 'zsh',
      currentPath: _workspace,
      paneTitle: 'SFTP · sample workspace',
    ),
  ];
}

class _AppReviewDemoWindowSpec {
  const _AppReviewDemoWindowSpec({
    required this.id,
    required this.panePid,
    required this.name,
    required this.currentCommand,
    required this.currentPath,
    required this.paneTitle,
    this.agentTool,
    this.agentSessionTitle,
  });

  final String id;
  final int panePid;
  final String name;
  final String currentCommand;
  final String currentPath;
  final String paneTitle;
  final AgentLaunchTool? agentTool;
  final String? agentSessionTitle;

  TmuxWindow toWindow({required int index, required bool isActive}) =>
      TmuxWindow(
        index: index,
        id: id,
        panePid: panePid,
        name: name,
        isActive: isActive,
        currentCommand: currentCommand,
        currentPath: currentPath,
        flags: isActive ? '*' : null,
        paneTitle: paneTitle,
        paneStartCommand: currentCommand,
        agentTool: agentTool,
        activeAgentSessionId: agentTool == null ? null : 'demo-$panePid',
        agentSessionTitle: agentSessionTitle,
        activeAgentSessionConfidence: agentTool == null
            ? null
            : AgentSessionConfidence.medium,
        idleSeconds: isActive ? 2 : 30,
      );
}

void _renderAppReviewDemoWindow(SshSession session, TmuxWindow window) {
  writeAppReviewDemoTerminalOutput(
    session,
    _appReviewDemoWindowScreen(window),
    replaceScreen: true,
    showPrompt: false,
  );
}

String _ansi(String code, String text) => '\x1b[${code}m$text\x1b[0m';

String _appReviewDemoWindowScreen(TmuxWindow window) {
  final title = window.displayTitle;
  final path = window.currentPath ?? '/home/reviewer/work/monkeyssh-demo';
  final tool = window.foregroundAgentTool;
  if (tool == AgentLaunchTool.copilotCli ||
      window.name.toLowerCase().contains('copilot')) {
    return '''
${_ansi('48;5;24;38;5;231;1', ' GitHub Copilot CLI (demo) ')} ${_ansi('38;5;245', 'agent  gpt-5.5  Window ${window.index}')}
${_ansi('38;5;39', '╭─ prompt ─────────────────────────────────────────────╮')}
${_ansi('38;5;39', '│')} Review PR #643                                      ${_ansi('38;5;39', '│')}
${_ansi('38;5;39', '╰───────────────────────────────────────────────────────╯')}

${_ansi('38;5;75;1', '●')} Reading workspace
  ${_ansi('38;5;70', '✓')} lib/domain/services/monkeymux_service.dart
  ${_ansi('38;5;70', '✓')} lib/domain/services/ssh_service.dart

${_ansi('38;5;75;1', '●')} Plan
  ${_ansi('38;5;70', '✓')} make demo MonkeyMux windows interactive
  ${_ansi('38;5;70', '✓')} repaint terminal on selection
  ${_ansi('38;5;70', '✓')} keep review data local

${_ansi('38;5;75;1', '●')} Suggested next step
  ${_ansi('38;5;231;48;5;25', ' /deploy ')}

${_ansi('38;5;240', '────────────────────────────────────────────────────────')}
${_ansi('38;5;245', 'Copilot is ready. Ask a follow-up or switch MonkeyMux windows.')}
''';
  }
  if (tool == AgentLaunchTool.claudeCode ||
      window.name.toLowerCase().contains('claude')) {
    return '''
${_ansi('38;5;208;1', '✻ Claude Code (demo)')} ${_ansi('38;5;245', 'Window ${window.index} · $title')}
${_ansi('38;5;238', '╭──────────────────────────────────────────────────────╮')}
${_ansi('38;5;238', '│')} ${_ansi('38;5;252;1', 'Working directory')}  ${_ansi('38;5;110', path)} ${_ansi('38;5;238', '│')}
${_ansi('38;5;238', '╰──────────────────────────────────────────────────────╯')}

${_ansi('38;5;208', '●')} Plan
  ${_ansi('38;5;70', '✓')} tighten App Review demo flow
  ${_ansi('38;5;70', '✓')} make MonkeyMux windows interactive
  ${_ansi('38;5;70', '✓')} run flutter analyze

${_ansi('38;5;208', '●')} Edits
  ${_ansi('38;5;214', 'M')} lib/domain/services/app_review_demo_service.dart
  ${_ansi('38;5;214', 'M')} test/domain/services/app_review_demo_ssh_service_test.dart

${_ansi('38;5;70;1', '✔')} Result: ready for review
${_ansi('38;5;245', 'Use the MonkeyMux bar to inspect another agent pane.')}
''';
  }
  if (tool == AgentLaunchTool.openCode ||
      window.name.toLowerCase().contains('opencode')) {
    return '''
${_ansi('48;5;22;38;5;231;1', ' OpenCode (demo) ')} ${_ansi('38;5;245', 'README.md  Window ${window.index}')}
${_ansi('38;5;36', '┌ files ─────────────┬ editor ─────────────────────────┐')}
${_ansi('38;5;36', '│')}  README.md        ${_ansi('38;5;36', '│')}  1  # MonkeySSH App Review Demo        ${_ansi('38;5;36', '│')}
${_ansi('38;5;36', '│')}  package.json     ${_ansi('38;5;36', '│')}  2                                      ${_ansi('38;5;36', '│')}
${_ansi('38;5;36', '│')}  src/main.dart     ${_ansi('38;5;36', '│')}  3  Local MonkeyMux windows exercise   ${_ansi('38;5;36', '│')}
${_ansi('38;5;36', '│')}  logs/app.log      ${_ansi('38;5;36', '│')}  4  switching, SFTP, snippets, tunnels. ${_ansi('38;5;36', '│')}
${_ansi('38;5;36', '│')}                  ${_ansi('38;5;36', '│')}  5                                      ${_ansi('38;5;36', '│')}
${_ansi('38;5;36', '│')}                  ${_ansi('38;5;36', '│')}  6  App Review can explore locally.     ${_ansi('38;5;36', '│')}
${_ansi('38;5;36', '└──────────────────┴──────────────────────────────────┘')}
${_ansi('48;5;235;38;5;252', ' NORMAL ')} ${_ansi('38;5;245', 'utf-8  ~/work/monkeyssh-demo/README.md')}
''';
  }
  if (tool == AgentLaunchTool.codex ||
      window.name.toLowerCase().contains('codex')) {
    return '''
${_ansi('38;5;51;1', 'Codex CLI (demo)')} ${_ansi('38;5;245', 'Window ${window.index} · $title')}
${_ansi('38;5;238', '╭──────────────────────────────────────────────────────╮')}
${_ansi('38;5;238', '│')} ${_ansi('38;5;231;1', 'Task')} implement local MonkeyMux demo window rendering ${_ansi('38;5;238', '│')}
${_ansi('38;5;238', '╰──────────────────────────────────────────────────────╯')}

${_ansi('38;5;51', 'thinking')} model local windows as an in-memory mux
${_ansi('38;5;51', 'thinking')} repaint terminal on select/create/close

${_ansi('38;5;70', '✓')} service branch added
${_ansi('38;5;70', '✓')} tests cover create and select
${_ansi('38;5;70', '✓')} analyzer clean

${_ansi('48;5;23;38;5;231', ' Patch ready ')}
''';
  }
  if (tool == AgentLaunchTool.geminiCli ||
      window.name.toLowerCase().contains('gemini')) {
    return '''
${_ansi('38;5;99;1', '✦ Gemini CLI (demo)')} ${_ansi('38;5;245', 'Window ${window.index} · $title')}
${_ansi('38;5;99', '╭──────────────── context ────────────────╮')}
${_ansi('38;5;99', '│')} ${_ansi('38;5;45', '✓')} PRODUCT.md                              ${_ansi('38;5;99', '│')}
${_ansi('38;5;99', '│')} ${_ansi('38;5;45', '✓')} DESIGN.md                               ${_ansi('38;5;99', '│')}
${_ansi('38;5;99', '│')} ${_ansi('38;5;45', '✓')} lib/domain/services/                 ${_ansi('38;5;99', '│')}
${_ansi('38;5;99', '╰──────────────────────────────────────────╯')}

${_ansi('38;5;45;1', 'Summary')}
  The App Review demo uses local MonkeyMux state.
  Switching windows changes this terminal screen.

${_ansi('38;5;245', 'Ready for another prompt.')}
''';
  }
  if (tool == AgentLaunchTool.antigravity ||
      window.name.toLowerCase().contains('antigravity')) {
    return '''
${_ansi('48;5;54;38;5;231;1', ' Antigravity (demo) ')} ${_ansi('38;5;245', 'Window ${window.index} · $title')}
${_ansi('38;5;141', '┌ objective ───────────────────────────────────────────┐')}
${_ansi('38;5;141', '│')} Verify mobile SSH agent workflows from the review device. ${_ansi('38;5;141', '│')}
${_ansi('38;5;141', '└──────────────────────────────────────────────────────┘')}

Workspace
  ${_ansi('38;5;111', '~/work/monkeyssh-demo')}

Status
  ${_ansi('38;5;70', '●')} local demo transport online
  ${_ansi('38;5;70', '●')} MonkeyMux navigator online
  ${_ansi('38;5;70', '●')} window switching changes the visible pane
''';
  }
  return '''
${_ansi('48;5;236;38;5;231;1', ' MonkeySSH SFTP / Shell (demo) ')} ${_ansi('38;5;245', 'Window ${window.index} · $title')}

$path

${_ansi('38;5;33', 'drwxr-xr-x')}  logs
${_ansi('38;5;33', 'drwxr-xr-x')}  screenshots
${_ansi('38;5;33', 'drwxr-xr-x')}  src
${_ansi('38;5;245', '-rw-r--r--')}  144  README.md
${_ansi('38;5;245', '-rw-r--r--')}   68  package.json
${_ansi('38;5;245', '-rwxr-xr-x')}   39  deploy-demo.sh

Tip:
  Tap the folder button to browse the same sample files in SFTP.
''';
}

TmuxWindow? _windowFromJson(Object? value) {
  if (value is! Map<String, Object?>) return null;
  final index = value['index'];
  final active = value['active'];
  final privateModes = _privateModesFromJson(value['privateModes']);
  final terminalReportsMouseWheel =
      (value['terminalReportsMouseWheel'] as bool? ?? false) ||
      _privateModeEnabled(privateModes, '1000') ||
      _privateModeEnabled(privateModes, '1002') ||
      _privateModeEnabled(privateModes, '1003');
  final terminalMouseReportSgr =
      (value['terminalMouseReportSgr'] as bool? ?? false) ||
      _privateModeEnabled(privateModes, '1006');
  // The MonkeyMux server only raises the `#` alert flag when a background
  // window emits a terminal bell (agents ring the bell when they need input),
  // and clears it as soon as the window is selected. Parsing it restores the
  // alert badge and the push notification for prompts/alerts without turning
  // ordinary background output into noisy notifications.
  return TmuxWindow(
    index: index is int ? index : 0,
    id: value['id'] as String?,
    name: value['name'] as String? ?? 'shell',
    isActive: active is bool && active,
    currentCommand: _nonEmpty(value['currentCommand'] as String?),
    currentPath: _nonEmpty(value['currentPath'] as String?),
    panePid: value['panePid'] as int?,
    flags: _nonEmpty(value['flags'] as String?),
    paneTitle: _nonEmpty(value['paneTitle'] as String?),
    agentTool: _agentToolFromMonkeyMuxMetadata(value['agentTool'] as String?),
    terminalReportsMouseWheel: terminalReportsMouseWheel,
    terminalMouseReportSgr: terminalMouseReportSgr,
    lastActivityEpochSeconds: value['lastActivityEpochSeconds'] as int?,
  );
}

Map<String, bool> _privateModesFromJson(Object? value) {
  if (value is! Map<String, Object?>) {
    return const <String, bool>{};
  }
  final privateModes = <String, bool>{};
  for (final entry in value.entries) {
    final modeValue = entry.value;
    if (modeValue is bool) {
      privateModes[entry.key] = modeValue;
    }
  }
  return privateModes;
}

bool _privateModeEnabled(Map<String, bool> privateModes, String mode) =>
    privateModes[mode] ?? false;

Set<int> _monkeyMuxAgentPanePids(Iterable<TmuxWindow> windows) => windows
    .where(
      (window) => window.foregroundAgentTool != null && window.panePid != null,
    )
    .map((window) => window.panePid!)
    .toSet();

/// Parses a MonkeyMux window snapshot for protocol regression tests.
@visibleForTesting
TmuxWindow? parseMonkeyMuxWindowSnapshotForTesting(Object? value) =>
    _windowFromJson(value);

/// Returns whether a MonkeyMux window list contains panes needing agent probes.
@visibleForTesting
bool shouldRefreshMonkeyMuxAgentMetadataForTesting(
  Iterable<TmuxWindow> windows,
) => _monkeyMuxAgentPanePids(windows).isNotEmpty;

/// Applies live agent metadata to MonkeyMux windows for regression tests.
@visibleForTesting
List<TmuxWindow> applyMonkeyMuxAgentMetadataForTesting(
  List<TmuxWindow> windows,
  String output,
) {
  final panePids = _monkeyMuxAgentPanePids(windows);
  return _applyMonkeyMuxAgentSessionMetadata(
    windows,
    parseAgentActiveSessionMetadataOutput(output, panePids),
    refreshedPanePids: panePids,
  ).windows;
}

/// Parses a MonkeyMux attach-state response for protocol regression tests.
@visibleForTesting
bool? parseMonkeyMuxHasForegroundClientForTesting(String line) =>
    _MonkeyMuxControlResponse.tryParse(line)?.hasForegroundClient;

/// Returns the one-shot control response timeout for protocol regression tests.
@visibleForTesting
Duration monkeyMuxOneShotResponseTimeoutForTesting(
  Map<String, Object?> request,
) => _oneShotResponseTimeout(request);

AgentLaunchTool? _agentToolFromMonkeyMuxMetadata(String? value) =>
    agentLaunchToolForCommandName(value);

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

/// Quotes a single MonkeyMux command argument for the remote shell. POSIX hosts
/// use single-quote escaping; Windows hosts use [_windowsQuoteArg], which
/// follows the CommandLineToArgvW parsing rules so embedded quotes and trailing
/// backslashes survive (helper path, session name, working directory, launch
/// command).
String _monkeyMuxQuoteArg(String value, {required bool windows}) =>
    windows ? _windowsQuoteArg(value) : _shellQuote(value);

/// Quotes [value] as a single Windows argument following the
/// CommandLineToArgvW / C runtime rules (the same algorithm as Go's
/// `syscall.EscapeArg`). Backslashes are only significant immediately before a
/// double quote, and a run of backslashes preceding a quote (or the closing
/// quote) is doubled. This correctly handles values containing spaces, embedded
/// double quotes (for example `python -c "print(1)"`) and trailing backslashes
/// (for example `C:\src\`), which naive `"$value"` wrapping would corrupt.
String _windowsQuoteArg(String value) {
  if (value.isEmpty) {
    return '""';
  }
  var needsQuotes = false;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit == 0x20 || unit == 0x09) {
      needsQuotes = true;
      break;
    }
  }
  final buffer = StringBuffer();
  if (needsQuotes) {
    buffer.write('"');
  }
  var backslashes = 0;
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    switch (unit) {
      case 0x5c: // backslash
        backslashes++;
        buffer.writeCharCode(unit);
      case 0x22: // double quote
        buffer
          ..write(r'\' * (backslashes + 1))
          ..writeCharCode(unit);
        backslashes = 0;
      default:
        backslashes = 0;
        buffer.writeCharCode(unit);
    }
  }
  if (needsQuotes) {
    buffer
      ..write(r'\' * backslashes)
      ..write('"');
  }
  return buffer.toString();
}

/// Builds the `<helper> control --json <session>` command for an installation,
/// quoting for the installed platform's shell.
String _buildMonkeyMuxControlCommand(
  MonkeyMuxInstallation installation,
  String sessionName,
) {
  final windows = installation.isWindows;
  return '${_monkeyMuxQuoteArg(installation.executablePath, windows: windows)} '
      'control --json '
      '${_monkeyMuxQuoteArg(sessionName, windows: windows)}';
}
