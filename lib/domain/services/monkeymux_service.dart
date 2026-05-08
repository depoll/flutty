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
import 'monkeymux_installer_service.dart';
import 'remote_multiplexer_service.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'tmux_service.dart';

/// MonkeyMux-backed implementation of [RemoteMultiplexerService].
final monkeyMuxServiceProvider = Provider<MonkeyMuxService>(
  (ref) =>
      MonkeyMuxService(installer: ref.watch(monkeyMuxInstallerServiceProvider)),
);

/// Builds the foreground attach command for an installed MonkeyMux helper.
String buildMonkeyMuxAttachCommand({
  required String executablePath,
  required String sessionName,
  String? workingDirectory,
}) {
  final parts = <String>[
    _shellQuote(executablePath),
    'attach',
    if (workingDirectory != null && workingDirectory.trim().isNotEmpty) ...[
      '--cwd',
      _shellQuote(workingDirectory.trim()),
    ],
    _shellQuote(sessionName),
  ];
  return parts.join(' ');
}

/// Controls a remote MonkeyMux session through its JSON backchannel.
class MonkeyMuxService implements RemoteMultiplexerService {
  /// Creates a MonkeyMux service.
  const MonkeyMuxService({required MonkeyMuxInstallerService installer})
    : _installer = installer;

  final MonkeyMuxInstallerService _installer;

  static final _observers =
      <_MonkeyMuxWatchKey, _MonkeyMuxWindowChangeObserver>{};
  static final _windowSnapshotCache = <_MonkeyMuxWatchKey, List<TmuxWindow>>{};
  static final _windowListRequests =
      <_MonkeyMuxWatchKey, Future<List<TmuxWindow>>>{};

  /// Clears MonkeyMux caches and watchers for a connection.
  Future<void> clearCache(int connectionId) async {
    DiagnosticsLogService.instance.info(
      'monkeymux.cache',
      'clear',
      fields: {'connectionId': connectionId},
    );
    _windowSnapshotCache.removeWhere(
      (key, _) => key.connectionId == connectionId,
    );
    _windowListRequests.removeWhere((key, request) {
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
    try {
      final response = await _runControlCommand(session, sessionName, {
        'type': 'list_windows',
      });
      final windows = await _enrichWindowsWithAgentMetadata(
        session,
        sessionName,
        response.windows,
      );
      _cacheWindows(key, windows);
      return windows;
    } on Object {
      final cachedWindows = _windowSnapshotCache[key];
      if (cachedWindows != null && cachedWindows.isNotEmpty) {
        return cachedWindows;
      }
      rethrow;
    }
  }

  @override
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) {
    final key = _MonkeyMuxWatchKey(session.connectionId, sessionName);
    final observer = _observers.putIfAbsent(
      key,
      () => _MonkeyMuxWindowChangeObserver(
        session: session,
        sessionName: sessionName,
        installer: _installer,
        onWindowList: (windows) => _cacheWindows(key, windows),
        onWindowSnapshot: (window) => _cacheWindowSnapshot(key, window),
        onDispose: () => _observers.remove(key),
      ),
    );
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
  }) async {
    await _runControlCommand(session, sessionName, {
      'type': 'select_window',
      if (windowId != null && windowId.trim().isNotEmpty)
        'windowId': windowId.trim()
      else
        'windowIndex': windowIndex,
    });
  }

  @override
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? extraFlags,
  }) async {
    await _runControlCommand(session, sessionName, {
      'type': 'close_window',
      'windowIndex': windowIndex,
    });
  }

  @override
  bool isExecChannelCoolingDown(SshSession session) => false;

  @override
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) async {
    await _runControlCommand(session, sessionName, {'type': 'ping'});
    return true;
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
  }) async {}

  Future<_MonkeyMuxControlResponse> _runControlCommand(
    SshSession session,
    String sessionName,
    Map<String, Object?> command, {
    SshExecPriority priority = SshExecPriority.normal,
  }) async {
    final observer =
        _observers[_MonkeyMuxWatchKey(session.connectionId, sessionName)];
    if (observer != null) {
      return observer.runCommand(command);
    }
    final installation = await _installer.ensureInstalled(session);
    final controlCommand =
        '${_shellQuote(installation.executablePath)} control --json '
        '${_shellQuote(sessionName)}';
    final commandId = DateTime.now().microsecondsSinceEpoch.toString();
    final request = <String, Object?>{'id': commandId, ...command};
    return session.runQueuedExec(
      () => _runOneShotControlCommand(session, controlCommand, request),
      priority: priority,
    );
  }

  Future<List<TmuxWindow>> _enrichWindowsWithAgentMetadata(
    SshSession session,
    String sessionName,
    List<TmuxWindow> windows,
  ) async {
    final panePids = windows
        .where(
          (window) =>
              window.foregroundAgentTool == AgentLaunchTool.copilotCli &&
              window.panePid != null,
        )
        .map((window) => window.panePid!)
        .toSet();
    if (panePids.isEmpty) {
      return windows;
    }

    try {
      final response = await _runControlCommand(session, sessionName, {
        'type': 'run_command',
        'command': buildCopilotActiveSessionMetadataCommand(panePids),
      }, priority: SshExecPriority.low);
      final metadataByPanePid = parseCopilotActiveSessionMetadataOutput(
        response.data ?? '',
        panePids,
      );
      if (metadataByPanePid.isEmpty) {
        return windows;
      }
      return windows
          .map((window) {
            final panePid = window.panePid;
            final metadata = panePid == null
                ? null
                : metadataByPanePid[panePid];
            if (metadata == null) return window;
            return window.copyWith(
              activeAgentSessionId: metadata.sessionId,
              agentSessionTitle: metadata.title,
            );
          })
          .toList(growable: false);
    } on Object catch (error) {
      DiagnosticsLogService.instance.debug(
        'monkeymux.agent',
        'active_session_metadata_failed',
        fields: {
          'connectionId': session.connectionId,
          'errorType': error.runtimeType,
        },
      );
      return windows;
    }
  }

  static void _cacheWindows(_MonkeyMuxWatchKey key, List<TmuxWindow> windows) {
    if (windows.isEmpty) return;
    _windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable(windows);
  }

  static void _cacheWindowSnapshot(_MonkeyMuxWatchKey key, TmuxWindow window) {
    final currentWindows = _windowSnapshotCache[key];
    if (currentWindows == null || currentWindows.isEmpty) {
      _windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable([window]);
      return;
    }
    _windowSnapshotCache[key] = List<TmuxWindow>.unmodifiable(
      applyTmuxWindowChangeEvent(
        currentWindows,
        TmuxWindowSnapshotEvent(window),
      ),
    );
  }
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
    await for (final line
        in execSession.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(const Duration(seconds: 10))) {
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
    await execSession.stdin.close();
    execSession.close();
  }
  throw const MonkeyMuxInstallException(
    'MonkeyMux control command closed without a response.',
  );
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
  final _commandQueue = Queue<_MonkeyMuxControlRequest>();
  final _pendingCommands = <String, _MonkeyMuxControlRequest>{};

  SSHSession? _controlSession;
  // Cancelled in _cleanup().
  // ignore: cancel_subscriptions
  StreamSubscription<String>? _stdoutSubscription;
  // Cancelled in _cleanup().
  // ignore: cancel_subscriptions
  StreamSubscription<void>? _doneSubscription;
  Future<void>? _startFuture;
  Future<void>? _disposeFuture;
  bool _disposed = false;

  Stream<TmuxWindowChangeEvent> get stream => _controller.stream;

  Future<_MonkeyMuxControlResponse> runCommand(
    Map<String, Object?> command,
  ) async {
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
    _commandQueue.add(request);
    _drainCommands();
    return request.future;
  }

  Future<void> _ensureStarted() {
    if (_disposed || _controlSession != null) return Future<void>.value();
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
      final installation = await installer.ensureInstalled(session);
      if (_disposed) return;
      final command =
          '${_shellQuote(installation.executablePath)} control --json '
          '${_shellQuote(sessionName)}';
      final controlSession = await session.execute(command);
      if (_disposed) {
        controlSession.close();
        return;
      }
      _controlSession = controlSession;
      _stdoutSubscription = controlSession.stdout
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine, onError: _handleError);
      _doneSubscription = controlSession.done.asStream().listen(
        (_) => _handleClosed(),
        onError: _handleError,
      );
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
    while (_commandQueue.isNotEmpty) {
      final request = _commandQueue.removeFirst();
      _pendingCommands[request.id] = request;
      controlSession.write(utf8.encode('${jsonEncode(request.payload)}\n'));
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
          if (window.foregroundAgentTool == AgentLaunchTool.copilotCli &&
              window.panePid != null) {
            _controller.add(const TmuxWindowReloadEvent());
          } else {
            _controller.add(TmuxWindowSnapshotEvent(window));
          }
        }
      case 'window_list':
        if (response.windows.isNotEmpty) {
          onWindowList(response.windows);
        }
      case 'active_window_changed':
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
    unawaited(_cleanup());
  }

  void _handleClosed() {
    if (_disposed) return;
    _failPending(
      const MonkeyMuxInstallException('MonkeyMux control channel closed.'),
      StackTrace.current,
    );
    unawaited(_cleanup());
  }

  void _failPending(Object error, StackTrace stackTrace) {
    while (_commandQueue.isNotEmpty) {
      _commandQueue.removeFirst().completeError(error, stackTrace);
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
    controlSession?.close();
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    if (_disposed) return;
    _disposed = true;
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

TmuxWindow? _windowFromJson(Object? value) {
  if (value is! Map<String, Object?>) return null;
  final index = value['index'];
  final active = value['active'];
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
    lastActivityEpochSeconds: value['lastActivityEpochSeconds'] as int?,
  );
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
