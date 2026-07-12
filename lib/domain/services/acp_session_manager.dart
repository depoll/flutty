import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_content.dart';
import '../models/acp_protocol.dart';
import '../models/acp_provider.dart';
import '../models/acp_recent_session.dart';
import '../models/acp_session_keys.dart';
import '../models/acp_session_state.dart';
import '../models/acp_timeline.dart';
import '../models/acp_updates.dart';
import '../models/monkeymux_acp_bridge.dart';
import 'acp_bridge_connector.dart';
import 'acp_client.dart';
import 'acp_concurrency_policy.dart';
import 'acp_json_rpc_connection.dart';
import 'acp_provider_service.dart';
import 'acp_recent_sessions_service.dart';
import 'diagnostics_log_service.dart';
import 'monetization_service.dart';
import 'monkeymux_acp_bridge_service.dart';
import 'monkeymux_installer_service.dart';
import 'ssh_service.dart';

/// Result of a request to start or reconnect a live ACP session.
@immutable
sealed class AcpSessionLaunchResult {
  const AcpSessionLaunchResult();
}

/// The requested live session started (or was already live) successfully.
@immutable
final class AcpSessionLaunchStarted extends AcpSessionLaunchResult {
  /// Creates a successful launch result.
  const AcpSessionLaunchStarted(this.key);

  /// Stable key of the started session.
  final AcpSessionKey key;
}

/// The free concurrency limit blocked the requested transition.
///
/// The caller must resolve this in the UI by stopping/replacing one of the
/// blocking sessions or unlocking [AcpConcurrencyRequiresChoice.requiredFeature].
/// Domain code never navigates or shows a paywall.
@immutable
final class AcpSessionLaunchBlocked extends AcpSessionLaunchResult {
  /// Creates a blocked launch result.
  const AcpSessionLaunchBlocked(this.decision);

  /// The concurrency choice the user must make.
  final AcpConcurrencyRequiresChoice decision;
}

/// The requested launch failed with a safe, categorized error.
@immutable
final class AcpSessionLaunchFailed extends AcpSessionLaunchResult {
  /// Creates a failed launch result.
  const AcpSessionLaunchFailed(this.key, this.error);

  /// Key of the session that failed, when one was allocated.
  final AcpSessionKey? key;

  /// Safe failure description.
  final AcpSessionError error;
}

/// Aggregate, immutable snapshot of every tracked ACP session.
@immutable
final class AcpSessionManagerState {
  /// Creates a manager state snapshot.
  ///
  /// [sessions] is defensively copied into an unmodifiable list.
  AcpSessionManagerState({
    List<AcpSessionState> sessions = const <AcpSessionState>[],
    this.selectedKey,
  }) : sessions = List<AcpSessionState>.unmodifiable(sessions);

  /// All tracked sessions, ordered by creation time.
  final List<AcpSessionState> sessions;

  /// Canonical value of the currently selected session, if any.
  final String? selectedKey;

  /// Returns the session state for [keyValue], if tracked.
  AcpSessionState? byKeyValue(String keyValue) =>
      sessions.firstWhereOrNullValue(keyValue);

  /// The currently selected session state, if any.
  AcpSessionState? get selected =>
      selectedKey == null ? null : byKeyValue(selectedKey!);

  /// Keys of sessions that currently count against the concurrency limit.
  Set<String> get liveSessionKeyValues => {
    for (final session in sessions)
      if (session.isLive) session.key.value,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionManagerState &&
          selectedKey == other.selectedKey &&
          listEquals(sessions, other.sessions);

  @override
  int get hashCode => Object.hash(selectedKey, Object.hashAll(sessions));
}

extension _FirstWhereOrNull on List<AcpSessionState> {
  AcpSessionState? firstWhereOrNullValue(String keyValue) {
    for (final session in this) {
      if (session.key.value == keyValue) return session;
    }
    return null;
  }
}

/// Manages multiple simultaneous ACP sessions across hosts and providers.
///
/// Each session runs in an isolated failure domain: one failed SSH connection,
/// bridge, or provider can never tear down unrelated sessions. Transcript
/// content lives only in each session's in-memory timeline and is never
/// persisted or logged.
class AcpSessionManager {
  /// Creates a session manager.
  AcpSessionManager({
    required AcpBridgeConnector connector,
    required AcpProviderService providerService,
    required AcpRecentSessionsService recentSessions,
    required bool Function() isProUnlocked,
    AcpConcurrencyPolicy concurrencyPolicy = const AcpConcurrencyPolicy(),
    DiagnosticsLogger? diagnostics,
    DateTime Function() clock = DateTime.now,
  }) : _connector = connector,
       _providerService = providerService,
       _recentSessions = recentSessions,
       _isProUnlocked = isProUnlocked,
       _policy = concurrencyPolicy,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance,
       _clock = clock;

  final AcpBridgeConnector _connector;
  final AcpProviderService _providerService;
  final AcpRecentSessionsService _recentSessions;
  final bool Function() _isProUnlocked;
  final AcpConcurrencyPolicy _policy;
  final DiagnosticsLogger _diagnostics;
  final DateTime Function() _clock;

  final Map<String, _SessionController> _controllers =
      <String, _SessionController>{};
  final Map<String, _BridgeAttachment> _attachments =
      <String, _BridgeAttachment>{};
  final StreamController<AcpSessionManagerState> _stateController =
      StreamController<AcpSessionManagerState>.broadcast();

  // Serializes lifecycle mutations so concurrency decisions always observe a
  // consistent live-session set.
  Future<void> _mutationQueue = Future<void>.value();

  String? _selectedKeyValue;
  AcpSessionManagerState _state = AcpSessionManagerState();
  var _disposed = false;

  /// Current aggregate state.
  AcpSessionManagerState get state => _state;

  /// Stream of aggregate state snapshots, starting with the current value.
  Stream<AcpSessionManagerState> get states async* {
    yield _state;
    yield* _stateController.stream;
  }

  /// Canonical values of every currently live session.
  Set<String> get liveSessionKeyValues => _state.liveSessionKeyValues;

  /// Starts a brand-new provider bridge and ACP session on [hostId].
  ///
  /// When the free concurrency limit is reached, returns
  /// [AcpSessionLaunchBlocked] without starting a bridge. Provide [replace] to
  /// first stop those live sessions and continue.
  Future<AcpSessionLaunchResult> startNewSession({
    required int hostId,
    required String providerId,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) => _serialize(() async {
    final launch = await _resolveLaunch(providerId);
    if (launch is _LaunchError) {
      return AcpSessionLaunchFailed(null, launch.error);
    }
    final resolved = launch as _ResolvedLaunch;

    await _stopAll(replace);

    final decision = _evaluate('\u0000new');
    if (decision is AcpConcurrencyRequiresChoice) {
      return AcpSessionLaunchBlocked(decision);
    }

    return _startBridgeAndSession(
      hostId: hostId,
      launch: resolved,
      cwd: cwd,
      confirmInstall: confirmInstall,
      existingSessionId: null,
    );
  });

  /// Reconnects to an existing remote bridge and resumes/loads its ACP session.
  ///
  /// Used on app restart, host reconnect, and when opening a recent session.
  /// If the session is already live and attached, it is simply selected.
  Future<AcpSessionLaunchResult> reconnectSession({
    required int hostId,
    required String providerId,
    required String bridgeId,
    required String acpSessionId,
    required String cwd,
    List<AcpSessionKey> replace = const <AcpSessionKey>[],
  }) => _serialize(() async {
    final key = AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
    );
    final existing = _controllers[key.value];
    if (existing != null && existing.state.isLive) {
      _select(key.value);
      return AcpSessionLaunchStarted(key);
    }

    final launch = await _resolveLaunch(providerId);
    if (launch is _LaunchError) {
      return AcpSessionLaunchFailed(key, launch.error);
    }
    final resolved = launch as _ResolvedLaunch;

    await _stopAll(replace);

    final decision = _evaluate(key.value);
    if (decision is AcpConcurrencyRequiresChoice) {
      return AcpSessionLaunchBlocked(decision);
    }

    // Re-attach an existing (detached) controller in place when possible.
    if (existing != null) {
      try {
        await existing.reconnect();
      } on _LaunchException catch (error) {
        _emit();
        return AcpSessionLaunchFailed(error.key ?? key, error.error);
      }
      _select(key.value);
      return AcpSessionLaunchStarted(key);
    }

    return _attachAndOpen(
      hostId: hostId,
      launch: resolved,
      bridgeId: bridgeId,
      cwd: cwd,
      existingSessionId: acpSessionId,
      confirmInstall: null,
    );
  });

  /// Lists safe metadata for remote bridges on [hostId].
  Future<List<MonkeyMuxAcpBridgeMetadata>> listRemoteBridges(int hostId) =>
      _connector.listBridges(hostId);

  /// Selects [key] as the active session and persists it as last-selected.
  Future<void> selectSession(AcpSessionKey key) async {
    if (!_controllers.containsKey(key.value)) return;
    _select(key.value);
    await _recentSessions.setLastSelected(key);
  }

  /// Sends a prompt turn on [key], snapshotting [content] atomically.
  Future<AcpPromptResult> prompt(
    AcpSessionKey key,
    List<AcpContentBlock> content,
  ) {
    final controller = _requireController(key);
    return controller.prompt(content);
  }

  /// Cancels the active prompt turn for [key].
  Future<void> cancelPrompt(AcpSessionKey key) =>
      _requireController(key).cancelPrompt();

  /// Sets a generic session configuration option.
  Future<void> setConfigOption(
    AcpSessionKey key, {
    required String configId,
    required Object value,
  }) =>
      _requireController(key).setConfigOption(configId: configId, value: value);

  /// Sets the legacy session mode.
  Future<void> setMode(AcpSessionKey key, String modeId) =>
      _requireController(key).setMode(modeId);

  /// Sets the legacy session model.
  Future<void> setModel(AcpSessionKey key, String modelId) =>
      _requireController(key).setModel(modelId);

  /// Answers a pending permission request with [optionId].
  Future<void> respondToPermission(
    AcpSessionKey key,
    String requestKey,
    String optionId,
  ) => _requireController(key).respondToPermission(requestKey, optionId);

  /// Cancels a pending permission request.
  Future<void> cancelPermission(AcpSessionKey key, String requestKey) =>
      _requireController(key).cancelPermission(requestKey);

  /// Detaches locally from [key] while leaving the remote bridge running.
  Future<void> detachSession(AcpSessionKey key) =>
      _serialize(() => _requireController(key).detach());

  /// Explicitly stops the remote bridge for [key] and releases resources.
  Future<void> stopSession(AcpSessionKey key) =>
      _serialize(() => _stopAll([key]));

  /// Closes the ACP session on the agent (when supported) and stops the bridge.
  Future<void> closeSession(AcpSessionKey key) => _serialize(() async {
    final controller = _controllers[key.value];
    if (controller == null) return;
    await controller.closeRemoteSession();
    await _stopAll([key]);
  });

  /// Deletes the stored ACP session (when supported), stops the bridge, and
  /// removes the recent-session reference.
  Future<void> deleteSession(AcpSessionKey key) => _serialize(() async {
    final controller = _controllers[key.value];
    if (controller != null) {
      await controller.deleteRemoteSession();
    }
    await _stopAll([key]);
    await _recentSessions.remove(key);
  });

  /// Forks [key] into a new ACP session on the same bridge, when supported.
  ///
  /// Returns the new session's launch result. The original session is not
  /// disturbed. Forking counts as a new live session for concurrency.
  Future<AcpSessionLaunchResult> forkSession(AcpSessionKey key) =>
      _serialize(() async {
        final controller = _controllers[key.value];
        if (controller == null) {
          return AcpSessionLaunchFailed(
            key,
            const AcpSessionError(
              kind: AcpSessionErrorKind.unknown,
              message: 'Session is not tracked.',
            ),
          );
        }
        final decision = _evaluate('\u0000fork');
        if (decision is AcpConcurrencyRequiresChoice) {
          return AcpSessionLaunchBlocked(decision);
        }
        return controller.fork();
      });

  /// Loads persisted recent sessions.
  Future<List<AcpRecentSessionRef>> loadRecentSessions() =>
      _recentSessions.list();

  /// Loads the persisted last-selected session key.
  Future<AcpSessionKey?> loadLastSelected() =>
      _recentSessions.getLastSelected();

  /// Releases every session, attachment, and stream. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final controllers = _controllers.values.toList(growable: false);
    _controllers.clear();
    for (final controller in controllers) {
      await controller.disposeLocal();
    }
    final attachments = _attachments.values.toList(growable: false);
    _attachments.clear();
    for (final attachment in attachments) {
      await attachment.forceClose();
    }
    await _stateController.close();
  }

  // ---- internal lifecycle ------------------------------------------------

  Future<AcpSessionLaunchResult> _startBridgeAndSession({
    required int hostId,
    required _ResolvedLaunch launch,
    required String cwd,
    required MonkeyMuxInstallConfirmation? confirmInstall,
    required String? existingSessionId,
  }) async {
    final startedAt = _clock();
    MonkeyMuxAcpBridgeStartResult startResult;
    try {
      startResult = await _connector.startBridge(
        hostId: hostId,
        providerId: launch.providerId,
        providerLabel: launch.label,
        launchArgv: launch.argv,
        cwd: cwd,
        confirmInstall: confirmInstall,
      );
    } on Object catch (error) {
      _diagnostics.error(
        'acp.manager',
        'bridge_start_failed',
        fields: {'hostId': hostId, 'errorType': error.runtimeType},
      );
      return AcpSessionLaunchFailed(null, _mapBridgeError(error));
    }
    return _attachAndOpen(
      hostId: hostId,
      launch: launch,
      bridgeId: startResult.bridgeId,
      cwd: cwd,
      existingSessionId: existingSessionId,
      confirmInstall: confirmInstall,
      startedBridge: true,
      bridgeStartedAt: startedAt,
    );
  }

  Future<AcpSessionLaunchResult> _attachAndOpen({
    required int hostId,
    required _ResolvedLaunch launch,
    required String bridgeId,
    required String cwd,
    required String? existingSessionId,
    required MonkeyMuxInstallConfirmation? confirmInstall,
    bool startedBridge = false,
    DateTime? bridgeStartedAt,
  }) async {
    final bridgeKey = AcpBridgeKey(
      host: AcpHostKey(hostId),
      bridgeId: bridgeId,
    );
    final attachment =
        _attachments[bridgeKey.value] ??
        _BridgeAttachment(
          bridgeKey: bridgeKey,
          providerId: launch.providerId,
          session: _connector.connect(
            hostId: hostId,
            bridgeId: bridgeId,
            providerId: launch.providerId,
          ),
        );
    _attachments[bridgeKey.value] = attachment;

    final controller = _SessionController(
      manager: this,
      attachment: attachment,
      providerLabel: launch.label,
      isCustomProvider: launch.isCustom,
      cwd: cwd,
      clock: _clock,
      diagnostics: _diagnostics,
    ).._acquireLease(attachment);

    try {
      final key = await controller.open(
        hostId: hostId,
        providerId: launch.providerId,
        bridgeId: bridgeId,
        existingSessionId: existingSessionId,
      );
      _controllers[key.value] = controller;
      _select(key.value);
      _emit();
      await _recordRecent(controller.state);
      _diagnostics.info(
        'acp.manager',
        'session_open',
        fields: {
          'hostId': hostId,
          'bridgeId': bridgeId,
          'reconnect': existingSessionId != null,
          if (bridgeStartedAt != null)
            'startMs': _clock().difference(bridgeStartedAt).inMilliseconds,
        },
      );
      return AcpSessionLaunchStarted(key);
    } on _LaunchException catch (error) {
      await controller.disposeLocal();
      await _maybeStopOrphanBridge(
        startedBridge: startedBridge,
        error: error.error,
        hostId: hostId,
        bridgeId: bridgeId,
      );
      return AcpSessionLaunchFailed(error.key, error.error);
    } on Object catch (error) {
      await controller.disposeLocal();
      final mapped = _mapBridgeError(error);
      await _maybeStopOrphanBridge(
        startedBridge: startedBridge,
        error: mapped,
        hostId: hostId,
        bridgeId: bridgeId,
      );
      return AcpSessionLaunchFailed(null, mapped);
    }
  }

  /// Best-effort stops a freshly started bridge that never produced a usable
  /// session, so a failed initialization does not orphan the remote process.
  ///
  /// The bridge is intentionally retained when the failure is a modeled
  /// authentication retry (the user completes auth out of band and retries),
  /// and when any other session still uses the bridge.
  Future<void> _maybeStopOrphanBridge({
    required bool startedBridge,
    required AcpSessionError error,
    required int hostId,
    required String bridgeId,
  }) async {
    if (!startedBridge) return;
    if (error.kind == AcpSessionErrorKind.authenticationRequired) return;
    final bridgeKey = AcpBridgeKey(
      host: AcpHostKey(hostId),
      bridgeId: bridgeId,
    );
    final stillUsed = _controllers.values.any(
      (controller) => controller.bridgeKey == bridgeKey,
    );
    if (stillUsed) return;
    try {
      await _connector.stopBridge(hostId, bridgeId);
      _diagnostics.info(
        'acp.manager',
        'orphan_bridge_stopped',
        fields: {'hostId': hostId, 'bridgeId': bridgeId},
      );
    } on Object catch (stopError) {
      _diagnostics.warning(
        'acp.manager',
        'orphan_bridge_stop_failed',
        fields: {'hostId': hostId, 'errorType': stopError.runtimeType},
      );
    }
  }

  Future<void> _recordRecent(AcpSessionState state) async {
    await _recentSessions.record(
      AcpRecentSessionRef(
        hostId: state.key.hostId,
        providerId: state.key.providerId,
        bridgeId: state.key.bridgeId,
        acpSessionId: state.key.acpSessionId,
        title: state.title,
        cwd: state.cwd,
        createdAt: state.createdAt,
        lastActivityAt: state.lastActivityAt,
      ),
    );
  }

  Future<void> _stopAll(List<AcpSessionKey> keys) async {
    for (final key in keys) {
      final controller = _controllers.remove(key.value);
      if (controller == null) continue;
      final hostId = key.hostId;
      final bridgeId = key.bridgeId;
      // Release the local lease (idempotent) and cancel streams.
      await controller.disposeLocal();
      // Explicit stop must terminate the remote bridge process even if this
      // session had detached locally, unless another live session still uses
      // that bridge (for example, a fork sharing the same provider process).
      final bridgeStillUsed = _controllers.values.any(
        (other) => other.bridgeKey == key.bridge,
      );
      if (bridgeStillUsed) continue;
      try {
        await _connector.stopBridge(hostId, bridgeId);
      } on Object catch (error) {
        _diagnostics.warning(
          'acp.manager',
          'bridge_stop_failed',
          fields: {'hostId': hostId, 'errorType': error.runtimeType},
        );
      }
    }
    _emit();
  }

  Future<bool> _releaseAttachment(_BridgeAttachment attachment) async {
    final closed = await attachment.release();
    if (closed &&
        identical(_attachments[attachment.bridgeKey.value], attachment)) {
      _attachments.remove(attachment.bridgeKey.value);
    }
    return closed;
  }

  AcpConcurrencyDecision _evaluate(String candidateKeyValue) =>
      _policy.evaluate(
        currentLiveSessionKeys: liveSessionKeyValues,
        candidateSessionKey: candidateKeyValue,
        isProUnlocked: _isProUnlocked(),
      );

  Future<_LaunchOutcome> _resolveLaunch(String providerId) async {
    final builtin = acpBuiltinProviders.firstWhereOrNull(
      (provider) => provider.id == providerId,
    );
    if (builtin != null) {
      return _ResolvedLaunch(
        providerId: builtin.id,
        label: builtin.label,
        argv: builtin.launchCommand.argv,
        isCustom: false,
      );
    }
    final custom = await _providerService.getCustomProvider(providerId);
    if (custom == null) {
      return const _LaunchError(
        AcpSessionError(
          kind: AcpSessionErrorKind.unknown,
          message: 'Unknown ACP provider.',
        ),
      );
    }
    if (!custom.isCommandApproved) {
      return const _LaunchError(
        AcpSessionError(
          kind: AcpSessionErrorKind.commandNotApproved,
          message: 'This provider\'s launch command must be re-approved.',
        ),
      );
    }
    return _ResolvedLaunch(
      providerId: custom.id,
      label: custom.label,
      argv: custom.launchCommand.argv,
      isCustom: true,
    );
  }

  _SessionController _requireController(AcpSessionKey key) {
    final controller = _controllers[key.value];
    if (controller == null) {
      throw StateError('No ACP session for the requested key.');
    }
    return controller;
  }

  void _select(String? keyValue) {
    _selectedKeyValue = keyValue;
    _emit();
  }

  void _onControllerChanged() => _emit();

  void _emit() {
    if (_disposed) return;
    final sessions =
        _controllers.values.map((controller) => controller.state).toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (_selectedKeyValue != null &&
        !_controllers.containsKey(_selectedKeyValue)) {
      _selectedKeyValue = sessions.isEmpty ? null : sessions.last.key.value;
    }
    _state = AcpSessionManagerState(
      sessions: sessions,
      selectedKey: _selectedKeyValue,
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _mutationQueue.then((_) => action());
    _mutationQueue = operation.then<void>((_) {}, onError: (_) {});
    return operation;
  }

  AcpSessionError _mapBridgeError(Object error) {
    if (error is MonkeyMuxAcpBridgeException) {
      return AcpSessionError(
        kind: switch (error.kind) {
          MonkeyMuxAcpBridgeErrorKind.helperUnavailable ||
          MonkeyMuxAcpBridgeErrorKind.helperProcess ||
          MonkeyMuxAcpBridgeErrorKind.invalidMetadata ||
          MonkeyMuxAcpBridgeErrorKind.unsupportedVersion =>
            AcpSessionErrorKind.bridgeUnavailable,
          MonkeyMuxAcpBridgeErrorKind.providerExited =>
            AcpSessionErrorKind.providerExited,
          MonkeyMuxAcpBridgeErrorKind.replayOverflow ||
          MonkeyMuxAcpBridgeErrorKind.sequenceGap ||
          MonkeyMuxAcpBridgeErrorKind.sshChannel ||
          MonkeyMuxAcpBridgeErrorKind.nonWriter ||
          MonkeyMuxAcpBridgeErrorKind.frameTooLarge ||
          MonkeyMuxAcpBridgeErrorKind.invalidFrame ||
          MonkeyMuxAcpBridgeErrorKind.closed => AcpSessionErrorKind.transport,
          MonkeyMuxAcpBridgeErrorKind.providerUnavailable =>
            AcpSessionErrorKind.providerExited,
          MonkeyMuxAcpBridgeErrorKind.invalidBridgeId ||
          MonkeyMuxAcpBridgeErrorKind.invalidLaunch =>
            AcpSessionErrorKind.bridgeUnavailable,
        },
        message: 'The remote agent bridge is unavailable.',
      );
    }
    return const AcpSessionError(
      kind: AcpSessionErrorKind.unknown,
      message: 'Failed to start the agent session.',
    );
  }
}

/// A reference-counted attachment to one remote bridge (one writer client).
///
/// Multiple sessions (for example, an original and its fork) can share a single
/// attachment. Its underlying client, JSON-RPC connection, and transport are
/// released only when the last leaseholder releases it. Release is guarded so
/// the reference count can never go negative and the transport is closed at
/// most once.
class _BridgeAttachment {
  _BridgeAttachment({
    required this.bridgeKey,
    required this.providerId,
    required AcpBridgeSession session,
  }) : _session = session;

  final AcpBridgeKey bridgeKey;
  final String providerId;
  final AcpBridgeSession _session;
  int _refCount = 0;
  AcpInitializeResult? _initialization;
  Future<AcpInitializeResult>? _initializeFuture;
  Future<void>? _closeFuture;
  var _terminated = false;

  AcpClient get client => _session.client;
  Stream<AcpSessionNotification> get notifications => client.updates;
  Stream<AcpServerRequest> get serverRequests => client.serverRequests;
  Stream<MonkeyMuxAcpTransportState> get transportStates =>
      _session.transportStates;
  Stream<MonkeyMuxAcpBridgeException> get transportErrors =>
      _session.transportErrors;
  AcpInitializeResult? get initialization => _initialization;

  /// Whether the underlying transport has terminally failed or been closed and
  /// this attachment must be replaced rather than reused on reconnect.
  bool get isTerminated => _terminated || _closeFuture != null;

  /// Current lease count. Exposed only for assertions and diagnostics.
  int get refCount => _refCount;

  /// Marks the transport as terminally unusable without releasing a lease, so
  /// the next reconnect replaces it. Idempotent.
  void markTerminated() => _terminated = true;

  void retain() => _refCount++;

  /// Releases one lease. Returns `true` only when this call dropped the last
  /// lease and closed the transport. Never decrements below zero and never
  /// closes the transport more than once.
  Future<bool> release() async {
    if (_refCount <= 0) return false;
    _refCount--;
    if (_refCount > 0) return false;
    await _close();
    return true;
  }

  Future<void> forceClose() async {
    _refCount = 0;
    await _close();
  }

  Future<void> _close() => _closeFuture ??= _session.close();

  Future<AcpInitializeResult> ensureInitialized() =>
      _initializeFuture ??= _doInitialize();

  Future<AcpInitializeResult> _doInitialize() async {
    final result = await client.initialize();
    _initialization = result;
    return result;
  }
}

/// Owns the normalized state and streaming lifecycle for one ACP session.
class _SessionController {
  _SessionController({
    required AcpSessionManager manager,
    required this.attachment,
    required String providerLabel,
    required bool isCustomProvider,
    required String cwd,
    required DateTime Function() clock,
    required DiagnosticsLogger diagnostics,
  }) : _manager = manager,
       _providerLabel = providerLabel,
       _isCustomProvider = isCustomProvider,
       _cwd = cwd,
       _clock = clock,
       _diagnostics = diagnostics;

  final AcpSessionManager _manager;

  /// Shared bridge attachment backing this session.
  _BridgeAttachment attachment;

  final String _providerLabel;
  final bool _isCustomProvider;
  final String _cwd;
  final DateTime Function() _clock;
  final DiagnosticsLogger _diagnostics;

  final AcpTimelineBuilder _timelineBuilder = AcpTimelineBuilder();
  final Map<String, AcpPermissionServerRequest> _pendingRequests =
      <String, AcpPermissionServerRequest>{};

  StreamSubscription<AcpSessionNotification>? _updatesSub;
  StreamSubscription<AcpServerRequest>? _serverRequestsSub;
  StreamSubscription<MonkeyMuxAcpTransportState>? _transportSub;
  StreamSubscription<MonkeyMuxAcpBridgeException>? _transportErrorSub;

  late AcpSessionState _state;
  late AcpSessionKey _key;
  var _holdsAttachment = false;
  var _disposed = false;

  /// Current immutable state.
  AcpSessionState get state => _state;

  /// Bridge key of the attachment currently backing this session.
  AcpBridgeKey get bridgeKey => _key.bridge;

  /// Acquires a lease on [target], making it this controller's attachment.
  void _acquireLease(_BridgeAttachment target) {
    attachment = target;
    target.retain();
    _holdsAttachment = true;
  }

  /// Releases this controller's lease exactly once, if it holds one.
  ///
  /// Returns whether releasing dropped the attachment's last lease (closing
  /// the local transport). A controller that already released (for example a
  /// detached original) never decrements the count again.
  Future<bool> _releaseLease() async {
    if (!_holdsAttachment) return false;
    _holdsAttachment = false;
    return _manager._releaseAttachment(attachment);
  }

  /// Opens the session: initializes the connection and creates/loads/resumes
  /// the ACP session capability-adaptively.
  Future<AcpSessionKey> open({
    required int hostId,
    required String providerId,
    required String bridgeId,
    required String? existingSessionId,
  }) async {
    final now = _clock();
    // Provisional key until the real session id is known.
    _key = AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: existingSessionId ?? '',
    );
    _state = AcpSessionState(
      key: _key,
      providerLabel: _providerLabel,
      isCustomProvider: _isCustomProvider,
      cwd: _cwd,
      status: AcpConnectionStatus.connecting,
      createdAt: now,
      lastActivityAt: now,
    );

    _subscribeTransport();

    AcpInitializeResult init;
    try {
      _update((s) => s.copyWith(status: AcpConnectionStatus.initializing));
      init = await attachment.ensureInitialized();
    } on Object catch (error) {
      throw _LaunchException(_key, _mapClientError(error));
    }

    _update(
      (s) => s.copyWith(initialization: init, authMethods: init.authMethods),
    );

    // For an existing session, the id is already known, so subscribe to session
    // updates BEFORE issuing session/load or session/resume. History replay is
    // emitted while the load RPC is still in flight; subscribing first ensures
    // those replayed updates are retained rather than dropped.
    if (existingSessionId != null) {
      _subscribeSessionStreams();
    }

    final resolvedSessionId = await _establishSession(existingSessionId, init);
    _key = AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: resolvedSessionId,
    );
    _update(
      (s) => s.copyWith(
        status: AcpConnectionStatus.ready,
        lastActivityAt: _clock(),
      ),
      key: _key,
    );

    // A brand-new session's id was unknown until session/new returned, so its
    // update subscription is established here.
    if (existingSessionId == null) {
      _subscribeSessionStreams();
    }
    return _key;
  }

  Future<String> _establishSession(
    String? existingSessionId,
    AcpInitializeResult init,
  ) async {
    final caps = init.agentCapabilities;
    try {
      if (existingSessionId == null) {
        final result = await attachment.client.newSession(cwd: _cwd);
        _applySetupResult(result);
        final id = result.sessionId;
        if (id == null || id.isEmpty) {
          throw _LaunchException(
            _key,
            const AcpSessionError(
              kind: AcpSessionErrorKind.protocol,
              message: 'The agent did not return a session id.',
            ),
          );
        }
        return id;
      }
      if (caps.session.resume) {
        final result = await attachment.client.resumeSession(
          sessionId: existingSessionId,
          cwd: _cwd,
        );
        _applySetupResult(result);
        return existingSessionId;
      }
      if (caps.loadSession) {
        final result = await attachment.client.loadSession(
          sessionId: existingSessionId,
          cwd: _cwd,
        );
        _applySetupResult(result);
        return existingSessionId;
      }
      // Neither resume nor load is advertised. Trust that the persistent
      // bridge kept the provider session alive and reuse the id directly.
      return existingSessionId;
    } on _LaunchException {
      rethrow;
    } on AcpRemoteException catch (error) {
      if (init.authMethods.isNotEmpty) {
        _update(
          (s) => s.copyWith(
            status: AcpConnectionStatus.authenticationRequired,
            pendingAuthentication: true,
            error: const AcpSessionError(
              kind: AcpSessionErrorKind.authenticationRequired,
              message: 'The agent requires authentication.',
            ),
          ),
        );
        throw _LaunchException(
          _key,
          const AcpSessionError(
            kind: AcpSessionErrorKind.authenticationRequired,
            message: 'The agent requires authentication.',
          ),
        );
      }
      throw _LaunchException(
        _key,
        AcpSessionError(
          kind: AcpSessionErrorKind.protocol,
          message: 'The agent rejected the session request (${error.code}).',
        ),
      );
    } on Object catch (error) {
      throw _LaunchException(_key, _mapClientError(error));
    }
  }

  void _applySetupResult(AcpSessionSetupResult result) {
    _update(
      (s) => s.copyWith(
        modeState: result.modes,
        modelState: result.models,
        configOptions: result.configOptions.isEmpty
            ? s.configOptions
            : result.configOptions,
      ),
    );
  }

  void _subscribeTransport() {
    _transportSub = attachment.transportStates.listen(_onTransportState);
    _transportErrorSub = attachment.transportErrors.listen(_onTransportError);
  }

  void _subscribeSessionStreams() {
    _updatesSub?.cancel();
    _serverRequestsSub?.cancel();
    _updatesSub = attachment.notifications
        .where((notification) => notification.sessionId == _key.acpSessionId)
        .listen(_onSessionUpdate);
    _serverRequestsSub = attachment.serverRequests.listen(_onServerRequest);
  }

  void _onSessionUpdate(AcpSessionNotification notification) {
    final update = notification.update;
    final timeline = _timelineBuilder.apply(update);
    _update((s) {
      var next = s.copyWith(lastActivityAt: _clock());
      if (timeline != null) next = next.copyWith(timeline: timeline);
      switch (update) {
        case AcpPlanUpdate(:final entries):
          next = next.copyWith(plan: entries);
        case AcpAvailableCommandsUpdate(:final commands):
          next = next.copyWith(availableCommands: commands);
        case AcpConfigOptionsUpdate(:final options):
          next = next.copyWith(configOptions: options);
        case AcpUsageUpdate():
          next = next.copyWith(usage: update);
        case AcpCurrentModeUpdate(:final modeId):
          final modes = next.modeState;
          if (modes != null) {
            next = next.copyWith(
              modeState: AcpSessionModeState(
                currentModeId: modeId,
                availableModes: modes.availableModes,
                meta: modes.meta,
                extensions: modes.extensions,
              ),
            );
          }
        case AcpCurrentModelUpdate(:final modelId):
          final models = next.modelState;
          if (models != null) {
            next = next.copyWith(
              modelState: AcpModelState(
                currentModelId: modelId,
                availableModels: models.availableModels,
                meta: models.meta,
                extensions: models.extensions,
              ),
            );
          }
        case AcpSessionInfoUpdate(:final hasTitle, :final title):
          if (hasTitle) {
            next = title == null
                ? next.copyWith(clearTitle: true)
                : next.copyWith(title: title);
          }
        case AcpContentChunkUpdate():
        case AcpToolCallUpdate():
        case AcpUnknownSessionUpdate():
          break;
      }
      return next;
    });
  }

  void _onServerRequest(AcpServerRequest request) {
    if (request is! AcpPermissionServerRequest) return;
    if (request.permission.sessionId != _key.acpSessionId) return;
    // Deduplicate by the stable JSON-RPC request id so a replayed permission
    // request (for example after reconnect) rebinds the responder onto the
    // current connection without appending a second pending UI entry.
    final requestKey = 'perm:${request.raw.id}';
    final isNew = !_pendingRequests.containsKey(requestKey);
    _pendingRequests[requestKey] = request;
    if (!isNew) {
      _diagnostics.debug(
        'acp.session',
        'permission_rebound',
        fields: {'pendingCount': _pendingRequests.length},
      );
      return;
    }
    final pending = AcpPendingPermission(
      requestKey: requestKey,
      sessionId: request.permission.sessionId,
      toolCallId: request.permission.toolCall.toolCallId,
      options: request.permission.options,
      requestedAt: _clock(),
    );
    _update(
      (s) => s.copyWith(pendingPermissions: [...s.pendingPermissions, pending]),
    );
    _diagnostics.debug(
      'acp.session',
      'permission_requested',
      fields: {'pendingCount': _pendingRequests.length},
    );
  }

  Future<void> respondToPermission(String requestKey, String optionId) async {
    final request = _pendingRequests.remove(requestKey);
    _removePending(requestKey);
    if (request == null) return;
    await request.select(optionId);
    _diagnostics.debug(
      'acp.session',
      'permission_resolved',
      fields: {'outcome': 'selected'},
    );
  }

  Future<void> cancelPermission(String requestKey) async {
    final request = _pendingRequests.remove(requestKey);
    _removePending(requestKey);
    if (request == null) return;
    await request.cancel();
    _diagnostics.debug(
      'acp.session',
      'permission_resolved',
      fields: {'outcome': 'cancelled'},
    );
  }

  void _removePending(String requestKey) {
    _update(
      (s) => s.copyWith(
        pendingPermissions: s.pendingPermissions
            .where((p) => p.requestKey != requestKey)
            .toList(growable: false),
      ),
    );
  }

  Future<AcpPromptResult> prompt(List<AcpContentBlock> content) async {
    final snapshot = List<AcpContentBlock>.unmodifiable(content);
    _update(
      (s) => s.copyWith(
        promptStatus: AcpPromptStatus.streaming,
        clearLastStopReason: true,
        lastActivityAt: _clock(),
      ),
    );
    try {
      final result = await attachment.client.prompt(
        sessionId: _key.acpSessionId,
        content: snapshot,
      );
      _update(
        (s) => s.copyWith(
          promptStatus: AcpPromptStatus.idle,
          lastStopReason: result.stopReason,
          lastActivityAt: _clock(),
        ),
      );
      return result;
    } on Object catch (error) {
      _update(
        (s) => s.copyWith(
          promptStatus: AcpPromptStatus.idle,
          error: _mapClientError(error),
        ),
      );
      rethrow;
    }
  }

  Future<void> cancelPrompt() async {
    _update((s) => s.copyWith(promptStatus: AcpPromptStatus.cancelling));
    await attachment.client.cancel(_key.acpSessionId);
  }

  Future<void> setConfigOption({
    required String configId,
    required Object value,
  }) async {
    final options = await attachment.client.setConfigOption(
      sessionId: _key.acpSessionId,
      configId: configId,
      value: value,
    );
    if (options.isNotEmpty) {
      _update((s) => s.copyWith(configOptions: options));
    }
  }

  Future<void> setMode(String modeId) async {
    await attachment.client.setMode(
      sessionId: _key.acpSessionId,
      modeId: modeId,
    );
    final modes = _state.modeState;
    if (modes != null) {
      _update(
        (s) => s.copyWith(
          modeState: AcpSessionModeState(
            currentModeId: modeId,
            availableModes: modes.availableModes,
            meta: modes.meta,
            extensions: modes.extensions,
          ),
        ),
      );
    }
  }

  Future<void> setModel(String modelId) async {
    await attachment.client.setModel(
      sessionId: _key.acpSessionId,
      modelId: modelId,
    );
  }

  Future<void> closeRemoteSession() async {
    try {
      await attachment.client.closeSession(_key.acpSessionId);
    } on AcpUnsupportedCapabilityException {
      // Closing is optional; ignore when unsupported.
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.session',
        'close_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  Future<void> deleteRemoteSession() async {
    try {
      await attachment.client.deleteSession(_key.acpSessionId);
    } on AcpUnsupportedCapabilityException {
      // Deleting is optional; ignore when unsupported.
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.session',
        'delete_failed',
        fields: {'errorType': error.runtimeType},
      );
    }
  }

  Future<AcpSessionLaunchResult> fork() async {
    try {
      final result = await attachment.client.forkSession(
        sessionId: _key.acpSessionId,
        cwd: _cwd,
      );
      final newId = result.sessionId;
      if (newId == null || newId.isEmpty) {
        return AcpSessionLaunchFailed(
          _key,
          const AcpSessionError(
            kind: AcpSessionErrorKind.protocol,
            message: 'The agent did not return a forked session id.',
          ),
        );
      }
      final forkController = _SessionController(
        manager: _manager,
        attachment: attachment,
        providerLabel: _providerLabel,
        isCustomProvider: _isCustomProvider,
        cwd: _cwd,
        clock: _clock,
        diagnostics: _diagnostics,
      ).._acquireLease(attachment);
      final key = await forkController.adoptForked(
        hostId: _key.hostId,
        providerId: _key.providerId,
        bridgeId: _key.bridgeId,
        acpSessionId: newId,
        setupResult: result,
      );
      _manager._controllers[key.value] = forkController;
      _manager
        .._select(key.value)
        .._emit();
      return AcpSessionLaunchStarted(key);
    } on AcpUnsupportedCapabilityException {
      return AcpSessionLaunchFailed(
        _key,
        const AcpSessionError(
          kind: AcpSessionErrorKind.unsupportedCapability,
          message: 'This agent does not support forking sessions.',
        ),
      );
    } on Object catch (error) {
      return AcpSessionLaunchFailed(_key, _mapClientError(error));
    }
  }

  /// Adopts an already-forked session id onto a fresh controller that shares
  /// the parent's bridge attachment.
  Future<AcpSessionKey> adoptForked({
    required int hostId,
    required String providerId,
    required String bridgeId,
    required String acpSessionId,
    required AcpSessionSetupResult setupResult,
  }) async {
    final now = _clock();
    _key = AcpSessionKey.of(
      hostId: hostId,
      providerId: providerId,
      bridgeId: bridgeId,
      acpSessionId: acpSessionId,
    );
    _state = AcpSessionState(
      key: _key,
      providerLabel: _providerLabel,
      isCustomProvider: _isCustomProvider,
      cwd: _cwd,
      status: AcpConnectionStatus.ready,
      createdAt: now,
      lastActivityAt: now,
      initialization: attachment.initialization,
      authMethods: attachment.initialization?.authMethods ?? const [],
    );
    _applySetupResult(setupResult);
    _subscribeTransport();
    _subscribeSessionStreams();
    return _key;
  }

  /// Detaches locally while leaving the remote bridge running.
  ///
  /// Idempotent: calling it again after the session is already detached (or has
  /// no lease) is a no-op and never decrements the shared attachment's
  /// reference count a second time. A detached original therefore can never
  /// stop a bridge still used by a fork.
  Future<void> detach() async {
    if (!_holdsAttachment) return;
    _update(
      (s) => s.copyWith(status: AcpConnectionStatus.detached, attached: false),
    );
    await _cancelSubscriptions();
    final closed = await _releaseLease();
    _diagnostics.info(
      'acp.session',
      'detached',
      fields: {'bridgeReleased': closed},
    );
  }

  /// Re-attaches a detached session and resumes/loads it.
  ///
  /// Replaces a terminally failed or closed attachment with a fresh one,
  /// cancels any stale subscriptions before resubscribing, balances the
  /// attachment lease, and surfaces failures as a typed [_LaunchException]
  /// after recording safe error state — it never throws a raw error.
  Future<void> reconnect() async {
    // Discard any stale subscriptions and lease left over from a previous
    // (possibly failed) attempt so retries start clean and balanced.
    await _cancelSubscriptions();
    await _releaseLease();

    final hostId = _key.hostId;
    final providerId = _key.providerId;
    final bridgeId = _key.bridgeId;
    final sessionId = _key.acpSessionId;
    final bridgeKey = AcpBridgeKey(
      host: AcpHostKey(hostId),
      bridgeId: bridgeId,
    );

    final existing = _manager._attachments[bridgeKey.value];
    final _BridgeAttachment target;
    if (existing != null && !existing.isTerminated) {
      target = existing;
    } else {
      if (existing != null) {
        _manager._attachments.remove(bridgeKey.value);
      }
      target = _BridgeAttachment(
        bridgeKey: bridgeKey,
        providerId: providerId,
        session: _manager._connector.connect(
          hostId: hostId,
          bridgeId: bridgeId,
          providerId: providerId,
        ),
      );
      _manager._attachments[bridgeKey.value] = target;
    }
    _acquireLease(target);

    _update(
      (s) => s.copyWith(
        status: AcpConnectionStatus.connecting,
        attached: true,
        clearError: true,
      ),
    );
    try {
      _subscribeTransport();
      final init = await attachment.ensureInitialized();
      _update((s) => s.copyWith(initialization: init));
      // Subscribe before load/resume so replayed history is retained.
      _subscribeSessionStreams();
      await _establishSession(sessionId, init);
      _update((s) => s.copyWith(status: AcpConnectionStatus.ready));
    } on Object catch (error) {
      final mapped = error is _LaunchException
          ? error.error
          : _mapClientError(error);
      _update(
        (s) => s.copyWith(
          status: AcpConnectionStatus.failed,
          attached: false,
          error: mapped,
        ),
      );
      await _cancelSubscriptions();
      await _releaseLease();
      throw _LaunchException(_key, mapped);
    }
  }

  void _onTransportState(MonkeyMuxAcpTransportState transportState) {
    _update((s) {
      var next = s.copyWith(transportState: transportState);
      switch (transportState.status) {
        case MonkeyMuxAcpTransportStatus.connecting:
          break;
        case MonkeyMuxAcpTransportStatus.connected:
          if (s.status == AcpConnectionStatus.reconnecting) {
            next = next.copyWith(status: AcpConnectionStatus.ready);
          }
        case MonkeyMuxAcpTransportStatus.reconnecting:
          if (s.attached) {
            next = next.copyWith(status: AcpConnectionStatus.reconnecting);
          }
        case MonkeyMuxAcpTransportStatus.providerExited:
          attachment.markTerminated();
          next = next.copyWith(
            status: AcpConnectionStatus.providerExited,
            attached: false,
            error: const AcpSessionError(
              kind: AcpSessionErrorKind.providerExited,
              message: 'The remote agent process exited.',
            ),
          );
        case MonkeyMuxAcpTransportStatus.failed:
          attachment.markTerminated();
          next = next.copyWith(
            status: AcpConnectionStatus.failed,
            error: const AcpSessionError(
              kind: AcpSessionErrorKind.transport,
              message: 'The agent connection failed.',
            ),
          );
        case MonkeyMuxAcpTransportStatus.closed:
          if (s.status != AcpConnectionStatus.detached) {
            next = next.copyWith(status: AcpConnectionStatus.closed);
          }
      }
      return next;
    });
  }

  void _onTransportError(MonkeyMuxAcpBridgeException error) {
    final kind = switch (error.kind) {
      MonkeyMuxAcpBridgeErrorKind.providerExited ||
      MonkeyMuxAcpBridgeErrorKind.providerUnavailable =>
        AcpSessionErrorKind.providerExited,
      MonkeyMuxAcpBridgeErrorKind.helperUnavailable ||
      MonkeyMuxAcpBridgeErrorKind.helperProcess ||
      MonkeyMuxAcpBridgeErrorKind.unsupportedVersion =>
        AcpSessionErrorKind.bridgeUnavailable,
      _ => AcpSessionErrorKind.transport,
    };
    _update(
      (s) => s.copyWith(
        error: AcpSessionError(
          kind: kind,
          message: 'The agent connection reported an error.',
        ),
      ),
    );
  }

  Future<void> disposeLocal() async {
    if (_disposed) return;
    _disposed = true;
    await _cancelSubscriptions();
    for (final request in _pendingRequests.values) {
      try {
        await request.cancel();
      } on Object {
        // Best-effort cancellation on teardown.
      }
    }
    _pendingRequests.clear();
    // Release the local lease exactly once (a no-op if already detached).
    await _releaseLease();
    if (_state.status != AcpConnectionStatus.detached) {
      _state = _state.copyWith(
        status: AcpConnectionStatus.closed,
        attached: false,
      );
    }
  }

  Future<void> _cancelSubscriptions() async {
    await _updatesSub?.cancel();
    await _serverRequestsSub?.cancel();
    await _transportSub?.cancel();
    await _transportErrorSub?.cancel();
    _updatesSub = null;
    _serverRequestsSub = null;
    _transportSub = null;
    _transportErrorSub = null;
  }

  void _update(
    AcpSessionState Function(AcpSessionState) transform, {
    AcpSessionKey? key,
  }) {
    _state = transform(_state);
    if (key != null && key != _state.key) {
      _state = AcpSessionState(
        key: key,
        providerLabel: _state.providerLabel,
        isCustomProvider: _state.isCustomProvider,
        cwd: _state.cwd,
        title: _state.title,
        status: _state.status,
        attached: _state.attached,
        createdAt: _state.createdAt,
        lastActivityAt: _state.lastActivityAt,
        initialization: _state.initialization,
        authMethods: _state.authMethods,
        pendingAuthentication: _state.pendingAuthentication,
        modeState: _state.modeState,
        modelState: _state.modelState,
        configOptions: _state.configOptions,
        availableCommands: _state.availableCommands,
        plan: _state.plan,
        usage: _state.usage,
        lastStopReason: _state.lastStopReason,
        promptStatus: _state.promptStatus,
        pendingPermissions: _state.pendingPermissions,
        transportState: _state.transportState,
        error: _state.error,
        timeline: _state.timeline,
      );
    }
    _manager._onControllerChanged();
  }

  AcpSessionError _mapClientError(Object error) => switch (error) {
    AcpUnsupportedCapabilityException() => const AcpSessionError(
      kind: AcpSessionErrorKind.unsupportedCapability,
      message: 'The agent does not support this operation.',
    ),
    AcpRequestTimeoutException() => const AcpSessionError(
      kind: AcpSessionErrorKind.timeout,
      message: 'The agent request timed out.',
    ),
    AcpProtocolException() => const AcpSessionError(
      kind: AcpSessionErrorKind.protocol,
      message: 'The agent sent invalid protocol data.',
    ),
    AcpConnectionClosedException() => const AcpSessionError(
      kind: AcpSessionErrorKind.transport,
      message: 'The agent connection closed.',
    ),
    MonkeyMuxAcpBridgeException() => _manager._mapBridgeError(error),
    _ => const AcpSessionError(
      kind: AcpSessionErrorKind.unknown,
      message: 'The agent session encountered an error.',
    ),
  };
}

/// Internal launch outcome union.
sealed class _LaunchOutcome {
  const _LaunchOutcome();
}

final class _ResolvedLaunch extends _LaunchOutcome {
  const _ResolvedLaunch({
    required this.providerId,
    required this.label,
    required this.argv,
    required this.isCustom,
  });

  final String providerId;
  final String label;
  final List<String> argv;
  final bool isCustom;
}

final class _LaunchError extends _LaunchOutcome {
  const _LaunchError(this.error);
  final AcpSessionError error;
}

class _LaunchException implements Exception {
  _LaunchException(this.key, this.error);
  final AcpSessionKey? key;
  final AcpSessionError error;
}

/// Provider for the production [AcpBridgeConnector].
final acpBridgeConnectorProvider = Provider<AcpBridgeConnector>((ref) {
  final bridgeService = ref.watch(monkeyMuxAcpBridgeServiceProvider);
  final sshService = ref.watch(sshServiceProvider);
  return MonkeyMuxAcpBridgeConnector(
    bridgeService: bridgeService,
    sessionResolver: (hostId) async {
      final session = sshService.getSessionsForHost(hostId).firstOrNull;
      if (session == null) {
        throw StateError('No active SSH session for host $hostId.');
      }
      return session;
    },
  );
});

/// Provider for the [AcpSessionManager].
final acpSessionManagerProvider = Provider<AcpSessionManager>((ref) {
  final manager = AcpSessionManager(
    connector: ref.watch(acpBridgeConnectorProvider),
    providerService: ref.watch(acpProviderServiceProvider),
    recentSessions: ref.watch(acpRecentSessionsServiceProvider),
    isProUnlocked: () =>
        ref.read(monetizationServiceProvider).currentState.isProUnlocked,
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// Streams the aggregate ACP session manager state.
final acpSessionManagerStateProvider = StreamProvider<AcpSessionManagerState>(
  (ref) => ref.watch(acpSessionManagerProvider).states,
);
