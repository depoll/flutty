/// Remote terminal multiplexer backend configured for a host.
enum RemoteMuxBackend {
  /// Let MonkeySSH choose the best available backend.
  auto,

  /// Use the bundled MonkeyMux helper when possible.
  monkeyMux,

  /// Use the remote host's tmux installation.
  tmux,
}

/// Persistence and presentation helpers for [RemoteMuxBackend].
extension RemoteMuxBackendPresentation on RemoteMuxBackend {
  /// Stable database value.
  String get storageValue => switch (this) {
    RemoteMuxBackend.auto => 'auto',
    RemoteMuxBackend.monkeyMux => 'monkey_mux',
    RemoteMuxBackend.tmux => 'tmux',
  };

  /// Human-readable label used in host settings.
  String get label => switch (this) {
    RemoteMuxBackend.auto => 'Automatic',
    RemoteMuxBackend.monkeyMux => 'MonkeyMux',
    RemoteMuxBackend.tmux => 'tmux',
  };

  /// Parses a stored backend value.
  static RemoteMuxBackend? fromStorageValue(String? value) => switch (value
      ?.trim()) {
    'auto' => RemoteMuxBackend.auto,
    'monkey_mux' || 'monkeyMux' || 'monkeymux' => RemoteMuxBackend.monkeyMux,
    'tmux' => RemoteMuxBackend.tmux,
    _ => null,
  };
}

/// Resolves the remote multiplexer backend a host should use at startup.
RemoteMuxBackend resolveRemoteMuxBackendForStartup({
  String? storedBackend,
  String? tmuxExtraFlags,
}) {
  final parsedBackend = RemoteMuxBackendPresentation.fromStorageValue(
    storedBackend,
  );
  if (parsedBackend != null) {
    return parsedBackend;
  }
  if (tmuxExtraFlags != null && tmuxExtraFlags.trim().isNotEmpty) {
    return RemoteMuxBackend.tmux;
  }
  return RemoteMuxBackend.auto;
}
