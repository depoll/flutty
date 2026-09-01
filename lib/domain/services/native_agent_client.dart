import '../models/acp_content.dart';
import '../models/acp_protocol.dart';
import '../models/acp_updates.dart';

/// Protocol-neutral client operations used by the native agent window manager.
///
/// ACP providers implement these operations directly. Provider-specific clients
/// may normalize richer protocols into the same in-memory session models so the
/// native conversation UI does not depend on one wire format.
abstract interface class NativeAgentClient {
  /// Streamed session updates normalized for the native conversation UI.
  Stream<AcpSessionNotification> get updates;

  /// Initializes the provider connection and reports supported operations.
  Future<AcpInitializeResult> initialize({Duration? timeout});

  /// Returns the process's fresh session.
  Future<AcpSessionSetupResult> newSession({
    required String cwd,
    Duration? timeout,
  });

  /// Loads a durable session and replays its visible history.
  Future<AcpSessionSetupResult> loadSession({
    required String sessionId,
    required String cwd,
    Duration? timeout,
  });

  /// Resumes a session already owned by the provider process.
  Future<AcpSessionSetupResult> resumeSession({
    required String sessionId,
    required String cwd,
    Duration? timeout,
  });

  /// Creates a provider-owned session fork when supported.
  Future<AcpSessionSetupResult> forkSession({
    required String sessionId,
    required String cwd,
    Duration? timeout,
  });

  /// Closes an active provider session when supported.
  Future<void> closeSession(String sessionId, {Duration? timeout});

  /// Deletes a durable provider session when supported.
  Future<void> deleteSession(String sessionId, {Duration? timeout});

  /// Sends one prompt and completes after the provider fully settles.
  Future<AcpPromptResult> prompt({
    required String sessionId,
    required List<AcpContentBlock> content,
    Duration? timeout,
  });

  /// Cancels the active prompt.
  Future<void> cancel(String sessionId);

  /// Changes a normalized session configuration option.
  Future<List<AcpSessionConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
    Duration? timeout,
  });

  /// Changes a legacy provider mode.
  Future<void> setMode({
    required String sessionId,
    required String modeId,
    Duration? timeout,
  });

  /// Changes the selected model.
  Future<void> setModel({
    required String sessionId,
    required String modelId,
    Duration? timeout,
  });

  /// Releases the protocol connection and transport.
  Future<void> close();
}
