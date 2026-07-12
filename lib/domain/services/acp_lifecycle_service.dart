import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_session_keys.dart';
import '../models/acp_session_state.dart';
import 'acp_session_manager.dart';
import 'auth_service.dart';
import 'diagnostics_log_service.dart';
import 'local_notification_service.dart';
import 'ssh_service.dart';

/// Coordinates ACP session behavior with app foreground/background state,
/// auth lock, and SSH host disconnects.
///
/// This never talks to a remote bridge directly: it only calls
/// [AcpSessionManager.detachSession]/[AcpSessionManager.reconnectSession],
/// which are already safe, idempotent, per-session operations. That keeps
/// this coordinator simple and means a bug here can never corrupt bridge
/// state, only fail to detach/reconnect a session locally.
///
/// No push notification is ever possible while the phone has no network path
/// to the SSH host: local notifications here are best-effort, in-app-only
/// signals shown while this process is still running in the background.
class AcpLifecycleService {
  /// Creates an ACP lifecycle coordinator.
  AcpLifecycleService({
    required AcpSessionManager sessionManager,
    required bool Function(int hostId) hasActiveSshSession,
    required LocalNotificationService notificationService,
    DiagnosticsLogger? diagnostics,
    this.backgroundDetachGrace = const Duration(seconds: 3),
  }) : _sessionManager = sessionManager,
       _hasActiveSshSession = hasActiveSshSession,
       _notificationService = notificationService,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance;

  /// How long a background transition must persist before this coordinator
  /// locally detaches live sessions.
  ///
  /// This absorbs brief OS-level flickers (for example a quick app-switcher
  /// glance or a system permission dialog) so they never churn a session;
  /// only a background period that outlasts this grace period is treated as
  /// a meaningful suspension.
  final Duration backgroundDetachGrace;

  final AcpSessionManager _sessionManager;
  final bool Function(int hostId) _hasActiveSshSession;
  final LocalNotificationService _notificationService;
  final DiagnosticsLogger _diagnostics;

  StreamSubscription<AcpSessionManagerState>? _stateSubscription;
  Timer? _backgroundTimer;
  bool _isForeground = true;
  bool _started = false;
  bool _disposed = false;

  // Keys this coordinator detached for backgrounding, so foreground only ever
  // reconnects sessions it itself put to sleep (never a session the user
  // explicitly stopped or detached).
  final Set<String> _autoDetachedKeyValues = <String>{};

  // Last known per-session state, used only to detect meaningful transitions
  // (a permission request appearing, a prompt turn completing) without
  // retaining any transcript content.
  final Map<String, AcpSessionState> _lastKnownStates =
      <String, AcpSessionState>{};

  var _acpNotificationId = 0;

  /// Starts observing session-manager state for notification gating.
  ///
  /// Safe to call more than once; only the first call attaches a listener.
  void start() {
    if (_started) return;
    _started = true;
    _stateSubscription = _sessionManager.states.listen(_onManagerStateChanged);
  }

  /// Releases this coordinator's subscriptions and pending timer.
  ///
  /// Never touches remote bridges: only local listeners/timers owned by this
  /// coordinator are released.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    await _stateSubscription?.cancel();
    _stateSubscription = null;
  }

  /// Call when the app returns to the foreground.
  ///
  /// Cancels any pending background-detach timer and best-effort reconnects
  /// every session this coordinator previously auto-detached, isolating each
  /// session's failure so one bad reconnect never blocks the others.
  Future<void> handleForeground() async {
    _isForeground = true;
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    await _reconnectAutoDetachedSessions();
  }

  /// Call when the app enters a background/inactive-adjacent state.
  ///
  /// Only [backgroundDetachGrace] after this call (and only if the app is
  /// still backgrounded then) are live sessions detached, so a transient
  /// state change never churns a session.
  Future<void> handleBackground() async {
    _isForeground = false;
    _backgroundTimer?.cancel();
    _backgroundTimer = Timer(backgroundDetachGrace, () {
      unawaited(_detachLiveSessionsForBackground());
    });
  }

  /// Call when the app locks (auto-lock or explicit lock).
  ///
  /// Detaches every live session locally without touching remote bridges, so
  /// a locked app never keeps a live client attached to a session the user
  /// can no longer see.
  Future<void> handleAuthLocked() async {
    final live = _sessionManager.state.sessions
        .where((session) => session.isLive)
        .toList(growable: false);
    for (final session in live) {
      await _detachSafely(session.key, reason: 'auth_locked');
    }
  }

  /// Call whenever the set of currently connected SSH hosts may have
  /// changed (for example after [SshService] active-session changes).
  ///
  /// Detaches every live ACP session whose host no longer has an active SSH
  /// session, isolating each host's cleanup from every other host's.
  Future<void> handleSshConnectivityChanged() async {
    final live = _sessionManager.state.sessions
        .where((session) => session.isLive)
        .toList(growable: false);
    for (final session in live) {
      if (_hasActiveSshSession(session.key.hostId)) {
        continue;
      }
      await _detachSafely(session.key, reason: 'ssh_disconnected');
    }
  }

  Future<void> _detachLiveSessionsForBackground() async {
    // The app may have already returned to the foreground before this timer
    // fired; that is not a meaningful suspension, so do nothing.
    if (_isForeground) return;
    final live = _sessionManager.state.sessions
        .where((session) => session.isLive)
        .toList(growable: false);
    for (final session in live) {
      final detached = await _detachSafely(session.key, reason: 'backgrounded');
      if (detached) {
        _autoDetachedKeyValues.add(session.key.value);
      }
    }
  }

  Future<void> _reconnectAutoDetachedSessions() async {
    if (_autoDetachedKeyValues.isEmpty) return;
    final keyValues = _autoDetachedKeyValues.toList(growable: false);
    _autoDetachedKeyValues.clear();
    for (final keyValue in keyValues) {
      final session = _sessionManager.state.byKeyValue(keyValue);
      // The session may have been explicitly stopped/deleted while
      // backgrounded; nothing to reconnect in that case.
      if (session == null) continue;
      try {
        // AcpSessionManager itself records the reconnect-outcome telemetry
        // for this call; this coordinator only needs a safe local log plus
        // per-session failure isolation.
        final result = await _sessionManager.reconnectSession(
          hostId: session.key.hostId,
          providerId: session.key.providerId,
          bridgeId: session.key.bridgeId,
          acpSessionId: session.key.acpSessionId,
          cwd: session.cwd,
        );
        _diagnostics.info(
          'acp.lifecycle',
          'foreground_reconnect',
          fields: {
            'hostId': session.key.hostId,
            'succeeded': result is AcpSessionLaunchStarted,
          },
        );
      } on Object catch (error) {
        // Isolate this session's failure: one bad reconnect must never block
        // reconnecting the rest.
        _diagnostics.warning(
          'acp.lifecycle',
          'foreground_reconnect_failed',
          fields: {
            'hostId': session.key.hostId,
            'errorType': error.runtimeType,
          },
        );
      }
    }
  }

  Future<bool> _detachSafely(
    AcpSessionKey key, {
    required String reason,
  }) async {
    try {
      await _sessionManager.detachSession(key);
      _diagnostics.info(
        'acp.lifecycle',
        'auto_detached',
        fields: {'hostId': key.hostId, 'reason': reason},
      );
      return true;
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.lifecycle',
        'auto_detach_failed',
        fields: {
          'hostId': key.hostId,
          'reason': reason,
          'errorType': error.runtimeType,
        },
      );
      return false;
    }
  }

  void _onManagerStateChanged(AcpSessionManagerState state) {
    final currentKeyValues = <String>{};
    for (final session in state.sessions) {
      currentKeyValues.add(session.key.value);
      final previous = _lastKnownStates[session.key.value];
      _maybeNotifyNewPermission(session, previous);
      _maybeNotifyCompletion(session, previous);
      _lastKnownStates[session.key.value] = session;
    }
    _lastKnownStates.removeWhere(
      (keyValue, _) => !currentKeyValues.contains(keyValue),
    );
  }

  void _maybeNotifyNewPermission(
    AcpSessionState session,
    AcpSessionState? previous,
  ) {
    final previousCount = previous?.pendingPermissions.length ?? 0;
    if (session.pendingPermissions.length <= previousCount) return;
    if (!_canNotify(session.key.hostId)) return;
    unawaited(
      _notificationService.showAcpNotification(
        notificationId: _nextAcpNotificationId(),
        title: '${session.providerLabel} needs your permission',
        body: 'Open the app to review and respond.',
        payload: AcpNotificationPayload(
          kind: AcpNotificationKind.permission,
          hostId: session.key.hostId,
          providerId: session.key.providerId,
          bridgeId: session.key.bridgeId,
          acpSessionId: session.key.acpSessionId,
        ),
      ),
    );
  }

  void _maybeNotifyCompletion(
    AcpSessionState session,
    AcpSessionState? previous,
  ) {
    final wasStreaming = switch (previous?.promptStatus) {
      AcpPromptStatus.sending || AcpPromptStatus.streaming => true,
      _ => false,
    };
    if (!wasStreaming) return;
    if (session.promptStatus != AcpPromptStatus.idle) return;
    if (session.lastStopReason == null) return;
    if (!_canNotify(session.key.hostId)) return;
    unawaited(
      _notificationService.showAcpNotification(
        notificationId: _nextAcpNotificationId(),
        title: '${session.providerLabel} finished',
        body: 'Open the app to see the result.',
        payload: AcpNotificationPayload(
          kind: AcpNotificationKind.completion,
          hostId: session.key.hostId,
          providerId: session.key.providerId,
          bridgeId: session.key.bridgeId,
          acpSessionId: session.key.acpSessionId,
        ),
      ),
    );
  }

  /// A local notification is only ever safe/useful while the app is
  /// backgrounded (so the user wouldn't otherwise see it) and there is a live
  /// SSH path to the host (so the state that triggered it is not already
  /// stale). There is no push path when disconnected, so this coordinator
  /// never attempts to notify in that case.
  bool _canNotify(int hostId) {
    if (_isForeground) return false;
    return _hasActiveSshSession(hostId);
  }

  int _nextAcpNotificationId() => ++_acpNotificationId;
}

/// Provider for [AcpLifecycleService].
final acpLifecycleServiceProvider = Provider<AcpLifecycleService>((ref) {
  final sshService = ref.watch(sshServiceProvider);
  final service = AcpLifecycleService(
    sessionManager: ref.watch(acpSessionManagerProvider),
    hasActiveSshSession: (hostId) =>
        sshService.getSessionsForHost(hostId).isNotEmpty,
    notificationService: ref.watch(localNotificationServiceProvider),
  )..start();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// Reacts to SSH active-session changes by detaching any ACP session whose
/// host lost its last active SSH session.
///
/// Kept as its own provider (rather than inline in
/// [acpLifecycleServiceProvider]) so tests can construct
/// [AcpLifecycleService] directly without pulling in the full Riverpod
/// SSH-session graph.
final acpSshConnectivityWatcherProvider = Provider<void>((ref) {
  final service = ref.watch(acpLifecycleServiceProvider);
  ref.listen<Map<int, SshConnectionState>>(activeSessionsProvider, (
    previous,
    next,
  ) {
    unawaited(service.handleSshConnectivityChanged());
  });
});

/// Reacts to auth-state transitions into `locked` by detaching every live
/// ACP session locally.
///
/// Kept as its own provider for the same reason as
/// [acpSshConnectivityWatcherProvider].
final acpAuthLockWatcherProvider = Provider<void>((ref) {
  final service = ref.watch(acpLifecycleServiceProvider);
  ref.listen<AuthState>(authStateProvider, (previous, next) {
    if (next == AuthState.locked && previous != AuthState.locked) {
      unawaited(service.handleAuthLocked());
    }
  });
});
