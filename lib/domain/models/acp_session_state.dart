import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import 'acp_protocol.dart';
import 'acp_session_keys.dart';
import 'acp_timeline.dart';
import 'acp_updates.dart';
import 'monkeymux_acp_bridge.dart';

/// High-level connection status of an ACP session as seen by the local app.
enum AcpConnectionStatus {
  /// No bridge/transport work has begun yet.
  idle,

  /// Starting or attaching to the remote bridge transport.
  connecting,

  /// The transport is up; the ACP `initialize`/session handshake is running.
  initializing,

  /// The agent requires authentication before a session can be used.
  authenticationRequired,

  /// The session is fully established and interactive.
  ready,

  /// The transport temporarily detached and is retrying.
  reconnecting,

  /// The session is intentionally detached locally; the remote bridge keeps
  /// running so it can be reconnected later.
  detached,

  /// The remote bridge could not be found or has expired.
  bridgeExpired,

  /// The remote provider process exited.
  providerExited,

  /// The session failed with a terminal error.
  failed,

  /// The session was explicitly closed and its resources released.
  closed,
}

/// Status of the current prompt turn for a session.
enum AcpPromptStatus {
  /// No prompt turn is in flight.
  idle,

  /// A prompt is being submitted.
  sending,

  /// The agent is streaming a response.
  streaming,

  /// A cancellation has been requested for the active turn.
  cancelling,
}

/// Stable, content-free error categories surfaced for an ACP session.
enum AcpSessionErrorKind {
  /// The remote bridge is unavailable or could not be installed.
  bridgeUnavailable,

  /// The remote bridge expired or no longer exists.
  bridgeExpired,

  /// The remote provider process exited unexpectedly.
  providerExited,

  /// The provider requires authentication that has not been completed.
  authenticationRequired,

  /// A requested ACP capability is not advertised by the agent.
  unsupportedCapability,

  /// The custom provider's command has not been approved for launch.
  commandNotApproved,

  /// The SSH transport failed or could not reconnect.
  transport,

  /// The ACP protocol was violated by the peer.
  protocol,

  /// A request exceeded its deadline.
  timeout,

  /// The free concurrency limit blocked the requested transition.
  concurrencyBlocked,

  /// An otherwise uncategorized failure.
  unknown,
}

/// A safe, content-free error surfaced for an ACP session.
///
/// [message] must never contain transcript content, prompts, paths, commands,
/// or any other sensitive data. It is a short, human-readable summary only.
@immutable
final class AcpSessionError {
  /// Creates a session error.
  const AcpSessionError({required this.kind, required this.message});

  /// Stable error category.
  final AcpSessionErrorKind kind;

  /// Short, safe description.
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionError &&
          kind == other.kind &&
          message == other.message;

  @override
  int get hashCode => Object.hash(kind, message);

  @override
  String toString() => 'AcpSessionError(${kind.name})';
}

/// A permission request awaiting a user decision.
///
/// Holds only the identifiers and choices needed to render and answer the
/// request. The tool-call content it references stays in the in-memory
/// timeline and is never persisted.
@immutable
final class AcpPendingPermission {
  /// Creates a pending permission reference.
  ///
  /// [options] is defensively copied into an unmodifiable list.
  AcpPendingPermission({
    required this.requestKey,
    required this.sessionId,
    required this.toolCallId,
    required List<AcpPermissionOption> options,
    required this.requestedAt,
  }) : options = List<AcpPermissionOption>.unmodifiable(options);

  /// Local key that uniquely identifies this pending request within a session.
  final String requestKey;

  /// Remote ACP session identifier the request belongs to.
  final String sessionId;

  /// Tool call awaiting permission.
  final String toolCallId;

  /// Choices offered by the agent.
  final List<AcpPermissionOption> options;

  /// When the request was first observed locally.
  final DateTime requestedAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpPendingPermission &&
          requestKey == other.requestKey &&
          sessionId == other.sessionId &&
          toolCallId == other.toolCallId &&
          requestedAt == other.requestedAt &&
          const ListEquality<AcpPermissionOption>().equals(
            options,
            other.options,
          );

  @override
  int get hashCode => Object.hash(
    requestKey,
    sessionId,
    toolCallId,
    requestedAt,
    const ListEquality<AcpPermissionOption>().hash(options),
  );
}

/// Immutable snapshot of a single ACP session's normalized state.
///
/// Everything here is either an identifier, a capability/config descriptor, a
/// coarse status, or in-memory streaming state. Transcript content lives only
/// inside [timeline], which is never persisted or logged.
@immutable
final class AcpSessionState {
  /// Creates a session state snapshot.
  ///
  /// Every list field is defensively copied into an unmodifiable list so a
  /// caller can never mutate a published snapshot after construction.
  AcpSessionState({
    required this.key,
    required this.providerLabel,
    required this.cwd,
    required this.status,
    required this.createdAt,
    required this.lastActivityAt,
    this.isCustomProvider = false,
    this.title,
    this.attached = true,
    this.initialization,
    List<AcpAuthMethod> authMethods = const <AcpAuthMethod>[],
    this.pendingAuthentication = false,
    this.modeState,
    this.modelState,
    List<AcpSessionConfigOption> configOptions =
        const <AcpSessionConfigOption>[],
    List<AcpAvailableCommand> availableCommands = const <AcpAvailableCommand>[],
    List<AcpPlanEntry> plan = const <AcpPlanEntry>[],
    this.usage,
    this.lastStopReason,
    this.promptStatus = AcpPromptStatus.idle,
    List<AcpPendingPermission> pendingPermissions =
        const <AcpPendingPermission>[],
    this.transportState,
    this.error,
    this.timeline = const AcpTimeline.empty(),
  }) : authMethods = List<AcpAuthMethod>.unmodifiable(authMethods),
       configOptions = List<AcpSessionConfigOption>.unmodifiable(configOptions),
       availableCommands = List<AcpAvailableCommand>.unmodifiable(
         availableCommands,
       ),
       plan = List<AcpPlanEntry>.unmodifiable(plan),
       pendingPermissions = List<AcpPendingPermission>.unmodifiable(
         pendingPermissions,
       );

  /// Stable composite identity of this session.
  final AcpSessionKey key;

  /// Provider display label.
  final String providerLabel;

  /// Whether the backing provider is a user-defined custom provider.
  final bool isCustomProvider;

  /// Working directory the session launched into.
  final String cwd;

  /// Optional session title reported by the agent.
  final String? title;

  /// High-level connection status.
  final AcpConnectionStatus status;

  /// Whether a local client is currently attached to the remote bridge.
  final bool attached;

  /// When the session was first created locally.
  final DateTime createdAt;

  /// Most recent local activity timestamp.
  final DateTime lastActivityAt;

  /// Most recent successful ACP initialization result, if any.
  final AcpInitializeResult? initialization;

  /// Authentication methods advertised by the agent.
  final List<AcpAuthMethod> authMethods;

  /// Whether the agent still requires authentication before use.
  final bool pendingAuthentication;

  /// Latest legacy mode state, if reported.
  final AcpSessionModeState? modeState;

  /// Latest legacy model state, if reported.
  final AcpModelState? modelState;

  /// Latest generic session configuration options.
  final List<AcpSessionConfigOption> configOptions;

  /// Latest available slash commands.
  final List<AcpAvailableCommand> availableCommands;

  /// Latest execution plan entries.
  final List<AcpPlanEntry> plan;

  /// Latest usage/context update.
  final AcpUsageUpdate? usage;

  /// Stop reason of the most recent completed prompt turn.
  final AcpStopReason? lastStopReason;

  /// Current prompt turn status.
  final AcpPromptStatus promptStatus;

  /// Permission requests awaiting a user decision.
  final List<AcpPendingPermission> pendingPermissions;

  /// Latest transport state, when connected through a MonkeyMux bridge.
  final MonkeyMuxAcpTransportState? transportState;

  /// Latest safe error surfaced for this session, if any.
  final AcpSessionError? error;

  /// In-memory normalized conversation timeline.
  final AcpTimeline timeline;

  /// Agent capabilities negotiated during initialization.
  AcpAgentCapabilities get capabilities =>
      initialization?.agentCapabilities ?? const AcpAgentCapabilities();

  /// Whether the session is currently live and locally attached.
  ///
  /// Live sessions are the ones counted by the concurrency policy. A detached,
  /// failed, expired, exited, or closed session is not live even though its
  /// remote bridge may still be running.
  bool get isLive =>
      attached &&
      switch (status) {
        AcpConnectionStatus.idle ||
        AcpConnectionStatus.connecting ||
        AcpConnectionStatus.initializing ||
        AcpConnectionStatus.authenticationRequired ||
        AcpConnectionStatus.ready ||
        AcpConnectionStatus.reconnecting => true,
        AcpConnectionStatus.detached ||
        AcpConnectionStatus.bridgeExpired ||
        AcpConnectionStatus.providerExited ||
        AcpConnectionStatus.failed ||
        AcpConnectionStatus.closed => false,
      };

  /// Returns a copy with the provided fields replaced.
  ///
  /// Nullable fields use dedicated `clear*` flags so an explicit `null` can be
  /// distinguished from "leave unchanged".
  AcpSessionState copyWith({
    String? providerLabel,
    String? cwd,
    String? title,
    bool clearTitle = false,
    AcpConnectionStatus? status,
    bool? attached,
    DateTime? lastActivityAt,
    AcpInitializeResult? initialization,
    List<AcpAuthMethod>? authMethods,
    bool? pendingAuthentication,
    AcpSessionModeState? modeState,
    bool clearModeState = false,
    AcpModelState? modelState,
    bool clearModelState = false,
    List<AcpSessionConfigOption>? configOptions,
    List<AcpAvailableCommand>? availableCommands,
    List<AcpPlanEntry>? plan,
    AcpUsageUpdate? usage,
    bool clearUsage = false,
    AcpStopReason? lastStopReason,
    bool clearLastStopReason = false,
    AcpPromptStatus? promptStatus,
    List<AcpPendingPermission>? pendingPermissions,
    MonkeyMuxAcpTransportState? transportState,
    bool clearTransportState = false,
    AcpSessionError? error,
    bool clearError = false,
    AcpTimeline? timeline,
  }) => AcpSessionState(
    key: key,
    providerLabel: providerLabel ?? this.providerLabel,
    isCustomProvider: isCustomProvider,
    cwd: cwd ?? this.cwd,
    title: clearTitle ? null : (title ?? this.title),
    status: status ?? this.status,
    attached: attached ?? this.attached,
    createdAt: createdAt,
    lastActivityAt: lastActivityAt ?? this.lastActivityAt,
    initialization: initialization ?? this.initialization,
    authMethods: authMethods ?? this.authMethods,
    pendingAuthentication: pendingAuthentication ?? this.pendingAuthentication,
    modeState: clearModeState ? null : (modeState ?? this.modeState),
    modelState: clearModelState ? null : (modelState ?? this.modelState),
    configOptions: configOptions ?? this.configOptions,
    availableCommands: availableCommands ?? this.availableCommands,
    plan: plan ?? this.plan,
    usage: clearUsage ? null : (usage ?? this.usage),
    lastStopReason: clearLastStopReason
        ? null
        : (lastStopReason ?? this.lastStopReason),
    promptStatus: promptStatus ?? this.promptStatus,
    pendingPermissions: pendingPermissions ?? this.pendingPermissions,
    transportState: clearTransportState
        ? null
        : (transportState ?? this.transportState),
    error: clearError ? null : (error ?? this.error),
    timeline: timeline ?? this.timeline,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionState &&
          key == other.key &&
          providerLabel == other.providerLabel &&
          isCustomProvider == other.isCustomProvider &&
          cwd == other.cwd &&
          title == other.title &&
          status == other.status &&
          attached == other.attached &&
          createdAt == other.createdAt &&
          lastActivityAt == other.lastActivityAt &&
          initialization == other.initialization &&
          pendingAuthentication == other.pendingAuthentication &&
          modeState == other.modeState &&
          modelState == other.modelState &&
          usage == other.usage &&
          lastStopReason == other.lastStopReason &&
          promptStatus == other.promptStatus &&
          transportState == other.transportState &&
          error == other.error &&
          timeline == other.timeline &&
          const ListEquality<AcpAuthMethod>().equals(
            authMethods,
            other.authMethods,
          ) &&
          const ListEquality<AcpSessionConfigOption>().equals(
            configOptions,
            other.configOptions,
          ) &&
          const ListEquality<AcpAvailableCommand>().equals(
            availableCommands,
            other.availableCommands,
          ) &&
          const ListEquality<AcpPlanEntry>().equals(plan, other.plan) &&
          const ListEquality<AcpPendingPermission>().equals(
            pendingPermissions,
            other.pendingPermissions,
          );

  @override
  int get hashCode => Object.hash(
    key,
    providerLabel,
    cwd,
    title,
    status,
    attached,
    createdAt,
    lastActivityAt,
    initialization,
    pendingAuthentication,
    promptStatus,
    usage,
    lastStopReason,
    transportState,
    error,
    timeline,
    Object.hash(
      const ListEquality<AcpAuthMethod>().hash(authMethods),
      const ListEquality<AcpSessionConfigOption>().hash(configOptions),
      const ListEquality<AcpAvailableCommand>().hash(availableCommands),
      const ListEquality<AcpPlanEntry>().hash(plan),
      const ListEquality<AcpPendingPermission>().hash(pendingPermissions),
    ),
  );
}
