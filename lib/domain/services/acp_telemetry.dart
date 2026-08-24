/// Coarse, allowlisted telemetry signals for ACP session lifecycle.
///
/// Implementations must stay privacy-safe: never accept or forward provider
/// commands, hostnames, usernames, working directories/paths, session
/// titles, model reasoning, prompts, tool arguments/output, attachment
/// content, or raw protocol data. Every method here only ever receives
/// coarse, pre-allowlisted category strings, counts, and booleans. Telemetry
/// must be opt-in and best-effort: failures must never affect session
/// behavior, which is why every method here returns `void` rather than a
/// `Future` that a caller might feel obliged to await or handle.
abstract interface class AcpTelemetrySink {
  /// The Agents feature surface was opened.
  void featureOpened();

  /// A live ACP session was opened, either freshly or by reconnecting.
  void sessionOpened({
    required String providerCategory,
    required bool isReconnect,
  });

  /// A live ACP session ended for a safe, coarse [reason].
  void sessionEnded({required String reason});

  /// A reconnect attempt finished, successfully or not.
  void reconnectOutcome({required bool succeeded, String? failureCategory});

  /// Attachments of [category] were included in a prompt turn.
  void attachmentSent({required String category, required int count});

  /// A permission or pending-write request was resolved with [outcome].
  void permissionOutcome({required String outcome});

  /// A safe, coarse failure category was observed.
  void failure({required String category});
}

/// A no-op sink used wherever telemetry has not been wired in (for example,
/// tests and fakes that do not exercise telemetry).
final class NoopAcpTelemetrySink implements AcpTelemetrySink {
  /// Creates a no-op telemetry sink.
  const NoopAcpTelemetrySink();

  @override
  void featureOpened() {}

  @override
  void sessionOpened({
    required String providerCategory,
    required bool isReconnect,
  }) {}

  @override
  void sessionEnded({required String reason}) {}

  @override
  void reconnectOutcome({required bool succeeded, String? failureCategory}) {}

  @override
  void attachmentSent({required String category, required int count}) {}

  @override
  void permissionOutcome({required String outcome}) {}

  @override
  void failure({required String category}) {}
}
