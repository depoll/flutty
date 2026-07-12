import '../services/acp_json_rpc_connection.dart';
import 'acp_updates.dart';

/// A user-decision request retained until it is explicitly answered.
sealed class AcpPendingClientRequest {
  /// Creates a retained client request.
  AcpPendingClientRequest(this.request);

  /// Current transport-bound request responder.
  AcpJsonRpcServerRequest request;

  /// JSON-RPC request identifier, stable across a bridge reconnect.
  String get id => request.id.toString();

  /// ACP session that owns this request, if supplied by the agent.
  String get sessionId;
}

/// A pending `session/request_permission` request.
final class AcpPendingPermission extends AcpPendingClientRequest {
  /// Creates a pending permission request.
  AcpPendingPermission(super.request, this.permission);

  /// Agent-provided permission details and exact selectable option IDs.
  final AcpPermissionRequest permission;

  @override
  String get sessionId => permission.sessionId;

  /// Answers with an exact option ID supplied by the agent.
  Future<void> select(String optionId) {
    if (!permission.options.any((option) => option.id == optionId)) {
      throw ArgumentError.value(
        optionId,
        'optionId',
        'Unknown permission option',
      );
    }
    return request.respond(<String, Object?>{
      'outcome': AcpSelectedPermissionOutcome(optionId).toJson(),
    });
  }

  /// Tells the agent that the pending request was cancelled.
  Future<void> cancel() => request.respond(<String, Object?>{
    'outcome': const AcpCancelledPermissionOutcome().toJson(),
  });
}

/// A write request waiting for an explicit local approval.
final class AcpPendingFileWrite extends AcpPendingClientRequest {
  /// Creates a pending file write.
  AcpPendingFileWrite({
    required AcpJsonRpcServerRequest request,
    required this.sessionId,
    required this.path,
    required this.content,
  }) : super(request);

  @override
  final String sessionId;

  /// Normalized remote target path. This is intentionally never logged.
  final String path;

  /// UTF-8 text to write. This is intentionally never logged.
  final String content;

  /// Completes this write after user approval.
  Future<void> approve(Future<void> Function() write) async {
    await write();
    await request.respond();
  }

  /// Refuses this write without exposing the target path or content.
  Future<void> reject() =>
      request.respondError(-32001, 'File write was not approved');
}
