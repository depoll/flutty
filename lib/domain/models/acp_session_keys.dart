import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Stable identity of a saved SSH host that can run ACP providers.
///
/// Host keys are derived only from the saved host's integer identifier, never
/// from hostnames, usernames, or any other connection content.
@immutable
final class AcpHostKey {
  /// Creates a host key for [hostId].
  const AcpHostKey(this.hostId);

  /// Saved host identifier.
  final int hostId;

  /// Canonical, content-free string form used for equality and diagnostics.
  String get value => 'h:$hostId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AcpHostKey && hostId == other.hostId;

  @override
  int get hashCode => hostId.hashCode;

  @override
  String toString() => 'AcpHostKey($value)';
}

/// Stable identity of an ACP provider definition (built-in or custom).
@immutable
final class AcpProviderKey {
  /// Creates a provider key for [providerId].
  const AcpProviderKey(this.providerId);

  /// Provider identifier.
  final String providerId;

  /// Canonical string form.
  String get value => 'p:$providerId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpProviderKey && providerId == other.providerId;

  @override
  int get hashCode => providerId.hashCode;

  @override
  String toString() => 'AcpProviderKey($value)';
}

/// Stable identity of a persistent remote MonkeyMux ACP bridge on one host.
///
/// A bridge is uniquely identified by the host it runs on plus the opaque
/// bridge UUID allocated by the remote helper.
@immutable
final class AcpBridgeKey {
  /// Creates a bridge key.
  const AcpBridgeKey({required this.host, required this.bridgeId});

  /// Host running the bridge.
  final AcpHostKey host;

  /// Opaque remote bridge identifier.
  final String bridgeId;

  /// Host identifier convenience accessor.
  int get hostId => host.hostId;

  /// Canonical string form.
  String get value => jsonEncode(<Object?>['bridge', host.hostId, bridgeId]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpBridgeKey && host == other.host && bridgeId == other.bridgeId;

  @override
  int get hashCode => Object.hash(host, bridgeId);

  @override
  String toString() => 'AcpBridgeKey(host: ${host.hostId})';
}

/// Stable composite identity of one live ACP session.
///
/// The key is a deterministic, injective function of the host, provider,
/// bridge, and remote ACP session identifier. Its [value] is the canonical
/// string used by the concurrency policy, recent-session persistence, and
/// diagnostics. It never contains transcript content.
@immutable
final class AcpSessionKey {
  /// Creates a session key from its components.
  const AcpSessionKey({
    required this.host,
    required this.provider,
    required this.bridgeId,
    required this.acpSessionId,
  });

  /// Creates a session key from raw identifiers.
  factory AcpSessionKey.of({
    required int hostId,
    required String providerId,
    required String bridgeId,
    required String acpSessionId,
  }) => AcpSessionKey(
    host: AcpHostKey(hostId),
    provider: AcpProviderKey(providerId),
    bridgeId: bridgeId,
    acpSessionId: acpSessionId,
  );

  /// Host running the provider.
  final AcpHostKey host;

  /// Provider definition backing the session.
  final AcpProviderKey provider;

  /// Opaque remote bridge identifier hosting the provider process.
  final String bridgeId;

  /// Remote ACP session identifier.
  final String acpSessionId;

  /// Host identifier convenience accessor.
  int get hostId => host.hostId;

  /// Provider identifier convenience accessor.
  String get providerId => provider.providerId;

  /// Bridge key convenience accessor.
  AcpBridgeKey get bridge => AcpBridgeKey(host: host, bridgeId: bridgeId);

  /// Canonical, content-free string form.
  ///
  /// Built with a JSON array so the four components can never collide even
  /// when an identifier happens to contain a separator character.
  String get value => jsonEncode(<Object?>[
    host.hostId,
    provider.providerId,
    bridgeId,
    acpSessionId,
  ]);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AcpSessionKey &&
          host == other.host &&
          provider == other.provider &&
          bridgeId == other.bridgeId &&
          acpSessionId == other.acpSessionId;

  @override
  int get hashCode => Object.hash(host, provider, bridgeId, acpSessionId);

  @override
  String toString() =>
      'AcpSessionKey(host: ${host.hostId}, provider: ${provider.providerId})';
}
