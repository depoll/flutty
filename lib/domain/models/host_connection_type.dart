/// How MonkeySSH reaches the SSH service for a saved host.
enum HostConnectionType {
  /// Connect directly to the configured hostname and port.
  ssh('ssh', 'Direct SSH'),

  /// Connect through a GitHub/Microsoft Dev Tunnel forwarding URL.
  devTunnel('dev_tunnel', 'Dev Tunnel');

  /// Creates a [HostConnectionType].
  const HostConnectionType(this.storageValue, this.label);

  /// Stable value persisted in the database.
  final String storageValue;

  /// Human-readable label used in host settings.
  final String label;
}

/// Resolves a stored host connection type value.
HostConnectionType hostConnectionTypeFromStorage(String? value) {
  for (final type in HostConnectionType.values) {
    if (type.storageValue == value) {
      return type;
    }
  }
  return HostConnectionType.ssh;
}
