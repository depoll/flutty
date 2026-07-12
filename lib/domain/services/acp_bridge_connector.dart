import 'dart:async';

import '../models/monkeymux_acp_bridge.dart';
import 'acp_client.dart';
import 'acp_json_rpc_connection.dart';
import 'monkeymux_acp_bridge_service.dart';
import 'monkeymux_installer_service.dart';
import 'ssh_service.dart';

/// A live bridge attachment: a typed ACP client plus the transport lifecycle
/// and error signals needed to drive session state.
///
/// This wraps whatever concrete transport a connector uses (in production, a
/// reconnecting MonkeyMux-over-SSH bridge transport). Closing it releases the
/// client, JSON-RPC connection, and transport deterministically.
final class AcpBridgeSession {
  /// Creates a bridge session.
  AcpBridgeSession({
    required this.client,
    required this.transportStates,
    required this.transportErrors,
    required Future<void> Function() onClose,
  }) : _onClose = onClose;

  /// Typed ACP client bound to the bridge transport.
  final AcpClient client;

  /// Transport lifecycle updates (connecting, reconnecting, exited, ...).
  final Stream<MonkeyMuxAcpTransportState> transportStates;

  /// Typed bridge/transport errors, kept separate from ACP payloads.
  final Stream<MonkeyMuxAcpBridgeException> transportErrors;

  final Future<void> Function() _onClose;
  Future<void>? _closeFuture;

  /// Releases the client, connection, and transport exactly once.
  Future<void> close() => _closeFuture ??= _onClose();
}

/// Abstraction over remote bridge lifecycle and ACP client construction.
///
/// The session manager depends only on this contract so it can be tested with
/// in-memory fakes and never has to construct an [SshSession] directly.
abstract interface class AcpBridgeConnector {
  /// Starts a new persistent provider bridge on [hostId] and returns its
  /// opaque identifier.
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  });

  /// Lists running bridges on [hostId].
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(int hostId);

  /// Reads safe metadata for [bridgeId] on [hostId].
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(int hostId, String bridgeId);

  /// Explicitly stops the remote provider and bridge [bridgeId] on [hostId].
  Future<void> stopBridge(int hostId, String bridgeId);

  /// Attaches to an existing bridge, returning a live ACP client bound to a
  /// reconnecting transport.
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
  });
}

/// Production [AcpBridgeConnector] backed by [MonkeyMuxAcpBridgeService] and
/// the typed ACP JSON-RPC client.
final class MonkeyMuxAcpBridgeConnector implements AcpBridgeConnector {
  /// Creates a connector.
  ///
  /// [sessionResolver] resolves the active [SshSession] for a saved host. It
  /// is invoked lazily so a bridge attachment can transparently reconnect
  /// through a freshly re-established SSH session.
  MonkeyMuxAcpBridgeConnector({
    required MonkeyMuxAcpBridgeService bridgeService,
    required Future<SshSession> Function(int hostId) sessionResolver,
    this.defaultRequestTimeout = const Duration(seconds: 60),
  }) : _bridgeService = bridgeService,
       _sessionResolver = sessionResolver;

  final MonkeyMuxAcpBridgeService _bridgeService;
  final Future<SshSession> Function(int hostId) _sessionResolver;

  /// Default per-request timeout applied to the ACP JSON-RPC connection.
  final Duration defaultRequestTimeout;

  @override
  Future<MonkeyMuxAcpBridgeStartResult> startBridge({
    required int hostId,
    required String providerId,
    required String providerLabel,
    required List<String> launchArgv,
    required String cwd,
    MonkeyMuxInstallConfirmation? confirmInstall,
  }) async {
    final session = await _sessionResolver(hostId);
    return _bridgeService.start(
      session: session,
      providerId: providerId,
      providerLabel: providerLabel,
      launchArgv: launchArgv,
      cwd: cwd,
      confirmInstall: confirmInstall,
    );
  }

  @override
  Future<List<MonkeyMuxAcpBridgeMetadata>> listBridges(int hostId) async {
    final session = await _sessionResolver(hostId);
    return _bridgeService.list(session);
  }

  @override
  Future<MonkeyMuxAcpBridgeMetadata> bridgeStatus(
    int hostId,
    String bridgeId,
  ) async {
    final session = await _sessionResolver(hostId);
    return _bridgeService.status(session, bridgeId);
  }

  @override
  Future<void> stopBridge(int hostId, String bridgeId) async {
    final session = await _sessionResolver(hostId);
    await _bridgeService.stop(session, bridgeId);
  }

  @override
  AcpBridgeSession connect({
    required int hostId,
    required String bridgeId,
    required String providerId,
  }) {
    final transport = _bridgeService.connect(
      sessionProvider: () => _sessionResolver(hostId),
      bridgeId: bridgeId,
      providerId: providerId,
    );
    final connection = AcpJsonRpcConnection(
      transport: transport,
      defaultRequestTimeout: defaultRequestTimeout,
    );
    final client = AcpClient(connection);
    return AcpBridgeSession(
      client: client,
      transportStates: transport.states,
      transportErrors: transport.errors,
      onClose: client.close,
    );
  }
}
