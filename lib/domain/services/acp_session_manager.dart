import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/acp_client_capabilities.dart' as cap;
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
import 'acp_client_capability_service.dart';
import 'acp_concurrency_policy.dart';
import 'acp_json_rpc_connection.dart';
import 'acp_provider_service.dart';
import 'acp_recent_sessions_service.dart';
import 'acp_telemetry.dart';
import 'acp_telemetry_adapter.dart';
import 'diagnostics_log_service.dart';
import 'monetization_service.dart';
import 'monkeymux_acp_bridge_service.dart';
import 'monkeymux_installer_service.dart';
import 'ssh_service.dart';
import 'telemetry_service.dart';

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
    AcpTelemetrySink telemetry = const NoopAcpTelemetrySink(),
    DateTime Function() clock = DateTime.now,
  }) : _connector = connector,
       _providerService = providerService,
       _recentSessions = recentSessions,
       _isProUnlocked = isProUnlocked,
       _policy = concurrencyPolicy,
       _diagnostics = diagnostics ?? DiagnosticsLogService.instance,
       _telemetry = telemetry,
       _clock = clock;

  final AcpBridgeConnector _connector;
  final AcpProviderService _providerService;
  final AcpRecentSessionsService _recentSessions;
  final bool Function() _isProUnlocked;
  final AcpConcurrencyPolicy _policy;
  final DiagnosticsLogger _diagnostics;
  final AcpTelemetrySink _telemetry;
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
    _telemetry.featureOpened();
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
    _telemetry.featureOpened();
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
    _reportAttachmentTelemetry(content);
    final controller = _requireController(key);
    return controller.prompt(content);
  }

  /// Reports coarse, allowlisted attachment counts for one prompt turn.
  ///
  /// Only category and count are reported; content, file names, and paths
  /// are never inspected beyond determining the ACP content-block type.
  void _reportAttachmentTelemetry(List<AcpContentBlock> content) {
    final counts = <String, int>{};
    for (final block in content) {
      final category = switch (block) {
        AcpImageContent() => 'image',
        AcpAudioContent() => 'audio',
        AcpResourceContent() || AcpResourceLinkContent() => 'resource',
        AcpTextContent() || AcpUnknownContent() => null,
      };
      if (category == null) continue;
      counts[category] = (counts[category] ?? 0) + 1;
    }
    counts.forEach(
      (category, count) =>
          _telemetry.attachmentSent(category: category, count: count),
    );
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

  /// Approves a pending file write after explicit user confirmation.
  Future<void> approveWrite(AcpSessionKey key, String requestKey) =>
      _requireController(key).approveWrite(requestKey);

  /// Rejects a pending file write.
  Future<void> rejectWrite(AcpSessionKey key, String requestKey) =>
      _requireController(key).rejectWrite(requestKey);

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
          capabilityServiceFactory: _capabilityServiceFactory(
            hostId: hostId,
            cwd: cwd,
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
      _telemetry.sessionOpened(
        providerCategory: launch.providerId,
        isReconnect: existingSessionId != null,
      );
      return AcpSessionLaunchStarted(key);
    } on _LaunchException catch (error) {
      await controller.disposeLocal();
      await _maybeStopOrphanBridge(
        startedBridge: startedBridge,
        hostId: hostId,
        bridgeId: bridgeId,
      );
      _telemetry.failure(category: error.error.kind.name);
      return AcpSessionLaunchFailed(error.key, error.error);
    } on Object catch (error) {
      await controller.disposeLocal();
      final mapped = _mapBridgeError(error);
      await _maybeStopOrphanBridge(
        startedBridge: startedBridge,
        hostId: hostId,
        bridgeId: bridgeId,
      );
      _telemetry.failure(category: mapped.kind.name);
      return AcpSessionLaunchFailed(null, mapped);
    }
  }

  /// Best-effort stops a freshly started bridge that never produced a usable
  /// session, so a failed launch does not orphan the remote process.
  ///
  /// This includes authentication-required failures: there is no
  /// authenticate/retry-on-existing-bridge path in this release, so a retained
  /// auth-blocked bridge would be unreachable and each retry would spawn
  /// another. The UI instead offers the provider's terminal-auth command and
  /// the user retries cleanly, starting a fresh bridge. The bridge is still
  /// retained when another session already uses it.
  Future<void> _maybeStopOrphanBridge({
    required bool startedBridge,
    required int hostId,
    required String bridgeId,
  }) async {
    if (!startedBridge) return;
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
      // Cancel only this session's own pending permission/write requests
      // before releasing its lease. When another live session (for example
      // a fork) still shares this bridge attachment, the attachment and its
      // capability service stay alive for that other session, so this must
      // not rely on a full `close()` to clean up: it would incorrectly
      // cancel the other session's pending requests too.
      await controller.attachment.capabilityService?.closeSession(
        key.acpSessionId,
      );
      // Release the local lease (idempotent) and cancel streams.
      await controller.disposeLocal();
      _telemetry.sessionEnded(reason: 'stopped');
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

  /// Builds a lazy capability-service factory bound to [hostId] and [cwd].
  ///
  /// Resolved once per [_BridgeAttachment], immediately before its first
  /// `initialize`, so it observes whichever SSH session is active for the
  /// host at that moment (including after an SSH reconnect). The capability
  /// service is always created so `session/request_permission` is always
  /// routed and answered; when no same-host filesystem/terminal binding can
  /// be resolved, `fs/*`/`terminal/*` requests are simply declined as
  /// unavailable rather than left unanswered.
  ///
  /// When [existingRegistry] is provided (a prior attachment's still-pending
  /// permission/write decisions, carried across a soft detach/reconnect), it
  /// is reused instead of creating an empty registry so those decisions stay
  /// visible immediately and rebind by request id once the agent replays
  /// them, rather than silently disappearing until/unless a replay arrives.
  Future<AcpClientCapabilityService> Function() _capabilityServiceFactory({
    required int hostId,
    required String cwd,
    AcpPendingRequestRegistry? existingRegistry,
  }) => () async {
    AcpHostCapabilityBinding? binding;
    try {
      binding = await _connector.resolveCapabilityBinding(hostId);
    } on Object catch (error) {
      _diagnostics.warning(
        'acp.manager',
        'capability_binding_failed',
        fields: {'hostId': hostId, 'errorType': error.runtimeType},
      );
      binding = null;
    }
    return AcpClientCapabilityService(
      fileSystem: binding?.fileSystem,
      terminalExecutor: binding?.terminalExecutor,
      allowedRoots: <String>[cwd],
      registry: existingRegistry ?? AcpPendingRequestRegistry(),
      diagnostics: _diagnostics,
    );
  };

  Future<bool> _releaseAttachment(
    _BridgeAttachment attachment, {
    bool permanent = false,
  }) async {
    final closed = await attachment.release(permanent: permanent);
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
    required Future<AcpClientCapabilityService> Function()
    capabilityServiceFactory,
  }) : _session = session,
       _capabilityServiceFactory = capabilityServiceFactory;

  final AcpBridgeKey bridgeKey;
  final String providerId;
  final AcpBridgeSession _session;
  final Future<AcpClientCapabilityService> Function() _capabilityServiceFactory;
  int _refCount = 0;
  AcpInitializeResult? _initialization;
  Future<AcpInitializeResult>? _initializeFuture;
  Future<void>? _closeFuture;
  AcpClientCapabilityService? _capabilityService;
  var _terminated = false;

  AcpClient get client => _session.client;
  Stream<AcpSessionNotification> get notifications => client.updates;
  Stream<MonkeyMuxAcpTransportState> get transportStates =>
      _session.transportStates;
  Stream<MonkeyMuxAcpBridgeException> get transportErrors =>
      _session.transportErrors;
  AcpInitializeResult? get initialization => _initialization;

  /// The capability service bound to this attachment's client, or `null` when
  /// no same-host filesystem/terminal binding was available at initialize
  /// time (the ACP session still works; fs/terminal requests are declined).
  AcpClientCapabilityService? get capabilityService => _capabilityService;

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
  ///
  /// [permanent] distinguishes a temporary local detach (the remote bridge
  /// stays alive and pending permissions/writes must survive to be replayed
  /// on the next reconnect) from a genuinely final teardown such as an
  /// explicit stop or app disposal, where outstanding requests are cancelled
  /// because no one will ever answer them.
  Future<bool> release({bool permanent = false}) async {
    if (_refCount <= 0) return false;
    _refCount--;
    if (_refCount > 0) return false;
    await _close(permanent: permanent);
    return true;
  }

  Future<void> forceClose() async {
    _refCount = 0;
    await _close(permanent: true);
  }

  Future<void> _close({required bool permanent}) =>
      _closeFuture ??= _performClose(permanent: permanent);

  Future<void> _performClose({required bool permanent}) async {
    if (permanent) {
      // Fully destroys session-owned terminals and pending requests: once
      // the last session leasing this bridge attachment releases it for
      // good, there is no one left to answer them.
      await _capabilityService?.close();
    } else {
      // Only stops routing new server requests locally; the registry (and
      // any pending permissions/writes) survives so the next reconnect can
      // rebind and replay them without duplicating or auto-answering them.
      await _capabilityService?.detach();
    }
    await _session.close();
  }

  Future<AcpInitializeResult> ensureInitialized() =>
      _initializeFuture ??= _doInitialize();

  Future<AcpInitializeResult> _doInitialize() async {
    final service = _capabilityService ??= await _capabilityServiceFactory();
    final result = await service.initialize(client);
    _initialization = result;
    return result;
  }
}

/// Maximum retained entries for session-scoped lists (plan steps, available
/// commands, config options) that a misbehaving agent could otherwise grow
/// without bound. Oldest entries are dropped, keeping the most recent state.
const _maxSessionListEntries = 200;

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

  StreamSubscription<AcpSessionNotification>? _updatesSub;
  StreamSubscription<List<cap.AcpPendingClientRequest>>? _capabilityRequestsSub;
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
  /// detached original) never decrements the count again. See
  /// [_BridgeAttachment.release] for the meaning of [permanent].
  Future<bool> _releaseLease({bool permanent = false}) async {
    if (!_holdsAttachment) return false;
    _holdsAttachment = false;
    return _manager._releaseAttachment(attachment, permanent: permanent);
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
            : _bounded(result.configOptions, _maxSessionListEntries),
      ),
    );
  }

  void _subscribeTransport() {
    _transportSub = attachment.transportStates.listen(_onTransportState);
    _transportErrorSub = attachment.transportErrors.listen(_onTransportError);
  }

  void _subscribeSessionStreams() {
    _updatesSub?.cancel();
    _capabilityRequestsSub?.cancel();
    _updatesSub = attachment.notifications
        .where((notification) => notification.sessionId == _key.acpSessionId)
        .listen(_onSessionUpdate);
    // The capability service (not this controller) is the sole subscriber of
    // `serverRequests`: it is the only place that answers fs/terminal/
    // permission requests, so there is exactly one responder per request.
    // This controller only mirrors the shared registry's current pending
    // requests for this session into UI-facing state.
    final capabilityService = attachment.capabilityService;
    if (capabilityService != null) {
      _onCapabilityRequestsChanged(capabilityService.registry.requests);
      _capabilityRequestsSub = capabilityService.registry.changes.listen(
        _onCapabilityRequestsChanged,
      );
    }
  }

  void _onSessionUpdate(AcpSessionNotification notification) {
    final update = notification.update;
    final timeline = _timelineBuilder.apply(update);
    _update((s) {
      var next = s.copyWith(lastActivityAt: _clock());
      if (timeline != null) next = next.copyWith(timeline: timeline);
      switch (update) {
        case AcpPlanUpdate(:final entries):
          next = next.copyWith(plan: _bounded(entries, _maxSessionListEntries));
        case AcpAvailableCommandsUpdate(:final commands):
          next = next.copyWith(
            availableCommands: _bounded(commands, _maxSessionListEntries),
          );
        case AcpConfigOptionsUpdate(:final options):
          next = next.copyWith(
            configOptions: _bounded(options, _maxSessionListEntries),
          );
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

  static List<T> _bounded<T>(List<T> values, int maxLength) =>
      values.length <= maxLength
      ? values
      : values.sublist(values.length - maxLength);

  /// Mirrors the shared capability registry's pending requests that belong to
  /// this ACP session into UI-facing [AcpSessionState] snapshots.
  ///
  /// This is the single place pending permissions/writes are derived: the
  /// registry (owned by the bridge attachment's capability service) is the
  /// only live responder, so there is nothing left to deduplicate here beyond
  /// filtering by session id.
  void _onCapabilityRequestsChanged(
    List<cap.AcpPendingClientRequest> requests,
  ) {
    final permissions = <AcpPendingPermission>[];
    final writes = <AcpPendingWrite>[];
    for (final request in requests) {
      if (request.sessionId != _key.acpSessionId) continue;
      switch (request) {
        case cap.AcpPendingPermission(:final permission):
          permissions.add(
            AcpPendingPermission(
              requestKey: request.id,
              sessionId: request.sessionId,
              toolCallId: permission.toolCall.toolCallId,
              options: permission.options,
              requestedAt: request.requestedAt,
            ),
          );
        case cap.AcpPendingFileWrite(:final path, :final content):
          writes.add(
            AcpPendingWrite(
              requestKey: request.id,
              sessionId: request.sessionId,
              path: path,
              contentByteLength: utf8.encode(content).length,
              requestedAt: request.requestedAt,
            ),
          );
      }
    }
    _update(
      (s) => s.copyWith(pendingPermissions: permissions, pendingWrites: writes),
    );
  }

  Future<void> respondToPermission(String requestKey, String optionId) async {
    final service = attachment.capabilityService;
    if (service == null) return;
    await service.selectPermission(requestKey, optionId);
    _diagnostics.debug(
      'acp.session',
      'permission_resolved',
      fields: {'outcome': 'selected'},
    );
    _manager._telemetry.permissionOutcome(outcome: 'selected');
  }

  Future<void> cancelPermission(String requestKey) async {
    final service = attachment.capabilityService;
    if (service == null) return;
    await service.cancelPermission(requestKey);
    _diagnostics.debug(
      'acp.session',
      'permission_resolved',
      fields: {'outcome': 'cancelled'},
    );
    _manager._telemetry.permissionOutcome(outcome: 'cancelled');
  }

  Future<void> approveWrite(String requestKey) async {
    final service = attachment.capabilityService;
    if (service == null) return;
    await service.approveWrite(requestKey);
    _diagnostics.debug(
      'acp.session',
      'write_resolved',
      fields: {'outcome': 'approved'},
    );
    _manager._telemetry.permissionOutcome(outcome: 'write_approved');
  }

  Future<void> rejectWrite(String requestKey) async {
    final service = attachment.capabilityService;
    if (service == null) return;
    await service.rejectWrite(requestKey);
    _diagnostics.debug(
      'acp.session',
      'write_resolved',
      fields: {'outcome': 'rejected'},
    );
    _manager._telemetry.permissionOutcome(outcome: 'write_rejected');
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
    // Captured before this controller's own lease is released: a solo
    // (non-forked) session's soft detach closes its bridge attachment, which
    // only *stops routing* new server requests locally (see
    // `_BridgeAttachment._performClose`) — it never cancels the capability
    // service's registry. Carrying that same registry into the replacement
    // attachment below preserves any still-pending permission/write
    // decisions across the detach instead of silently discarding them in
    // favor of a fresh, empty registry.
    final priorRegistry = attachment.capabilityService?.registry;

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
        capabilityServiceFactory: _manager._capabilityServiceFactory(
          hostId: hostId,
          cwd: _cwd,
          existingRegistry: priorRegistry,
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
      _manager._telemetry.reconnectOutcome(succeeded: true);
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
      _manager._telemetry.reconnectOutcome(
        succeeded: false,
        failureCategory: mapped.kind.name,
      );
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
          _manager._telemetry.sessionEnded(reason: 'provider_exited');
        case MonkeyMuxAcpTransportStatus.failed:
          attachment.markTerminated();
          next = next.copyWith(
            status: AcpConnectionStatus.failed,
            error: const AcpSessionError(
              kind: AcpSessionErrorKind.transport,
              message: 'The agent connection failed.',
            ),
          );
          _manager._telemetry.sessionEnded(reason: 'transport_failed');
        case MonkeyMuxAcpTransportStatus.closed:
          if (s.status != AcpConnectionStatus.detached) {
            next = next.copyWith(status: AcpConnectionStatus.closed);
          }
      }
      return next;
    });
    switch (transportState.status) {
      case MonkeyMuxAcpTransportStatus.providerExited:
      case MonkeyMuxAcpTransportStatus.failed:
      case MonkeyMuxAcpTransportStatus.closed:
        // The transport is confirmed gone (not merely reconnecting): release
        // local subscriptions and the attachment lease so terminals and
        // stream listeners never leak. This never stops an unrelated bridge:
        // it only releases this controller's own lease, and the shared
        // attachment only closes once every session leasing it has done so.
        unawaited(_cleanUpAfterTerminalTransport());
      case MonkeyMuxAcpTransportStatus.connecting:
      case MonkeyMuxAcpTransportStatus.connected:
      case MonkeyMuxAcpTransportStatus.reconnecting:
        break;
    }
  }

  Future<void> _cleanUpAfterTerminalTransport() async {
    await _cancelSubscriptions();
    await _releaseLease();
  }

  void _onTransportError(MonkeyMuxAcpBridgeException error) {
    // A replay-buffer overflow is a non-fatal warning: history emitted while
    // detached could not be replayed, but the session stays usable and can be
    // reloaded. Preserve it in `warning`, distinct from a fatal `error`, and
    // never change the connection status.
    if (error.kind == MonkeyMuxAcpBridgeErrorKind.replayOverflow) {
      _update(
        (s) => s.copyWith(
          warning: const AcpSessionError(
            kind: AcpSessionErrorKind.replayOverflow,
            message:
                'Some history from while you were disconnected could not be '
                'replayed. The session can continue, or reload it to fetch '
                'full history.',
          ),
        ),
      );
      _diagnostics.info(
        'acp.session',
        'replay_overflow',
        fields: {'attached': _state.attached},
      );
      return;
    }
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
    // Release the local lease exactly once (a no-op if already detached).
    // Permanent: this session is being explicitly stopped, deleted, or torn
    // down with the app, so the capability service's registry is cancelled
    // when this was the attachment's last lease rather than left pending.
    await _releaseLease(permanent: true);
    if (_state.status != AcpConnectionStatus.detached) {
      _state = _state.copyWith(
        status: AcpConnectionStatus.closed,
        attached: false,
      );
    }
  }

  Future<void> _cancelSubscriptions() async {
    await _updatesSub?.cancel();
    await _capabilityRequestsSub?.cancel();
    await _transportSub?.cancel();
    await _transportErrorSub?.cancel();
    _updatesSub = null;
    _capabilityRequestsSub = null;
    _transportSub = null;
    _transportErrorSub = null;
  }

  void _update(
    AcpSessionState Function(AcpSessionState) transform, {
    AcpSessionKey? key,
  }) {
    _state = transform(_state);
    // Rebuild under a new identity through the single copyWith path so no
    // field can ever be silently dropped when the key changes.
    if (key != null && key != _state.key) {
      _state = _state.copyWith(key: key);
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
    telemetry: AcpTelemetryAdapter(ref.watch(telemetryServiceProvider)),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

/// Streams the aggregate ACP session manager state.
final acpSessionManagerStateProvider = StreamProvider<AcpSessionManagerState>(
  (ref) => ref.watch(acpSessionManagerProvider).states,
);
