import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/terminal_theme.dart';
import '../models/tmux_state.dart';
import 'ssh_exec_queue.dart';
import 'ssh_service.dart';
import 'tmux_service.dart';

/// Common app-side surface for remote terminal multiplexers.
abstract interface class RemoteMultiplexerService {
  /// Returns the current window list for [sessionName].
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  });

  /// Watches remote window state changes for [sessionName].
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  });

  /// Returns the active pane context, if the backend can report one.
  Future<TmuxPaneContext?> currentPaneContext(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  });

  /// Returns the active pane path, if available.
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

  /// Creates a new remote window.
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
    String? workingDirectory,
    String? extraFlags,
  });

  /// Selects a remote window.
  ///
  /// [clientImageSignatures] maps Kitty image ids the client already holds to
  /// their content signature, so a backend that replays retained images (e.g.
  /// MonkeyMux) can skip re-transmitting ones the client can render from cache.
  Future<void> selectWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
    Map<int, int>? clientImageSignatures,
  });

  /// Closes a remote window.
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? extraFlags,
  });

  /// Returns whether short-lived exec control is cooling down.
  bool isExecChannelCoolingDown(SshSession session);

  /// Verifies whether the visible terminal is attached to [sessionName].
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  });

  /// Returns the foreground multiplexer session name, if any.
  Future<String?> foregroundSessionNameOrThrow(
    SshSession session, {
    String? extraFlags,
  });

  /// Refreshes visible clients after a theme change.
  Future<void> refreshTerminalTheme(
    SshSession session,
    String sessionName,
    TerminalThemeData theme, {
    String? extraFlags,
  });
}

/// tmux-backed implementation of [RemoteMultiplexerService].
class TmuxRemoteMultiplexerService implements RemoteMultiplexerService {
  /// Creates a tmux-backed multiplexer adapter.
  const TmuxRemoteMultiplexerService(this._tmuxService);

  final TmuxService _tmuxService;

  @override
  Future<List<TmuxWindow>> listWindows(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) => _tmuxService.listWindows(session, sessionName, extraFlags: extraFlags);

  @override
  Stream<TmuxWindowChangeEvent> watchWindowChanges(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) => _tmuxService.watchWindowChanges(
    session,
    sessionName,
    extraFlags: extraFlags,
  );

  @override
  Future<TmuxPaneContext?> currentPaneContext(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) => _tmuxService.currentPaneContext(
    session,
    sessionName,
    priority: priority,
    extraFlags: extraFlags,
  );

  @override
  Future<String?> currentPanePath(
    SshSession session,
    String sessionName, {
    SshExecPriority priority = SshExecPriority.normal,
    String? extraFlags,
  }) => _tmuxService.currentPanePath(
    session,
    sessionName,
    priority: priority,
    extraFlags: extraFlags,
  );

  @override
  Future<void> createWindow(
    SshSession session,
    String sessionName, {
    String? command,
    String? name,
    String? workingDirectory,
    String? extraFlags,
  }) => _tmuxService.createWindow(
    session,
    sessionName,
    command: command,
    name: name,
    workingDirectory: workingDirectory,
    extraFlags: extraFlags,
  );

  @override
  Future<void> selectWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? windowId,
    String? extraFlags,
    Map<int, int>? clientImageSignatures,
  }) => _tmuxService.selectWindow(
    session,
    sessionName,
    windowIndex,
    windowId: windowId,
    extraFlags: extraFlags,
  );

  @override
  Future<void> killWindow(
    SshSession session,
    String sessionName,
    int windowIndex, {
    String? extraFlags,
  }) => _tmuxService.killWindow(
    session,
    sessionName,
    windowIndex,
    extraFlags: extraFlags,
  );

  @override
  bool isExecChannelCoolingDown(SshSession session) =>
      _tmuxService.isExecChannelCoolingDown(session);

  @override
  Future<bool> hasForegroundClientOrThrow(
    SshSession session,
    String sessionName, {
    String? extraFlags,
  }) => _tmuxService.hasForegroundClientOrThrow(
    session,
    sessionName,
    extraFlags: extraFlags,
  );

  @override
  Future<String?> foregroundSessionNameOrThrow(
    SshSession session, {
    String? extraFlags,
  }) => _tmuxService.foregroundSessionNameOrThrow(
    session,
    extraFlags: extraFlags,
  );

  @override
  Future<void> refreshTerminalTheme(
    SshSession session,
    String sessionName,
    TerminalThemeData theme, {
    String? extraFlags,
  }) => _tmuxService.refreshTerminalTheme(
    session,
    sessionName,
    theme,
    extraFlags: extraFlags,
  );
}

/// tmux adapter provider for generic multiplexer consumers.
final tmuxRemoteMultiplexerServiceProvider = Provider<RemoteMultiplexerService>(
  (ref) => TmuxRemoteMultiplexerService(ref.watch(tmuxServiceProvider)),
);
