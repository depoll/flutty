import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../data/database/database.dart';
import '../../data/repositories/known_hosts_repository.dart';

/// The user decision for a presented SSH host key.
enum HostKeyTrustDecision {
  /// Trust an unknown host key.
  trust,

  /// Replace an existing trusted host key with the presented key.
  replace,

  /// Reject the presented host key.
  reject,
}

/// Callback used to collect a host-key trust decision from the UI.
typedef HostKeyPromptHandler =
    Future<HostKeyTrustDecision> Function(HostKeyVerificationRequest request);

/// An SSH host key presented during connection setup.
class VerifiedHostKey {
  /// Creates a [VerifiedHostKey].
  VerifiedHostKey({
    required this.hostname,
    required this.port,
    required this.keyType,
    required Uint8List hostKeyBytes,
  }) : hostKeyBytes = Uint8List.fromList(hostKeyBytes),
       fingerprint = formatSshHostKeyFingerprint(hostKeyBytes),
       md5Fingerprint = formatLegacySshHostKeyFingerprint(hostKeyBytes),
       encodedHostKey = base64.encode(hostKeyBytes);

  /// The host name being verified.
  final String hostname;

  /// The SSH port being verified.
  final int port;

  /// The SSH host-key algorithm reported by the server.
  final String keyType;

  /// The raw SSH wire-format host key bytes.
  final Uint8List hostKeyBytes;

  /// The SHA-256 fingerprint shown to the user and persisted.
  final String fingerprint;

  /// The legacy MD5 fingerprint accepted for imported entries.
  final String md5Fingerprint;

  /// The base64-encoded raw host key persisted in the database.
  final String encodedHostKey;

  /// Human-readable host label used in prompts and errors.
  String get hostLabel => '$hostname:$port';

  /// Whether this key matches an existing trusted host entry.
  bool matches(KnownHost knownHost) {
    if (knownHost.keyType != keyType) {
      return false;
    }

    if (knownHost.hostKey.isNotEmpty) {
      return knownHost.hostKey == encodedHostKey;
    }

    return knownHost.fingerprint == fingerprint ||
        knownHost.fingerprint == md5Fingerprint;
  }
}

/// A host-key verification request shown to the user.
class HostKeyVerificationRequest {
  /// Creates a [HostKeyVerificationRequest].
  const HostKeyVerificationRequest({
    required this.presentedHostKey,
    required this.existingKnownHost,
  });

  /// The host key the server just presented.
  final VerifiedHostKey presentedHostKey;

  /// The trusted entry already stored for the host, if any.
  final KnownHost? existingKnownHost;

  /// Whether the host already has a stored trust record.
  bool get isReplacement => existingKnownHost != null;

  /// Human-readable host label used in prompts and errors.
  String get hostLabel => presentedHostKey.hostLabel;
}

enum _TrustedHostUpdateMode { touch, upsert }

/// A deferred persistence action to apply after authentication succeeds.
class PendingHostTrustUpdate {
  PendingHostTrustUpdate._({
    required VerifiedHostKey presentedHostKey,
    required _TrustedHostUpdateMode mode,
    bool resetFirstSeen = false,
  }) : _presentedHostKey = presentedHostKey,
       _mode = mode,
       _resetFirstSeen = resetFirstSeen;

  /// Creates an update that refreshes the stored host key metadata.
  factory PendingHostTrustUpdate.touch(VerifiedHostKey presentedHostKey) =>
      PendingHostTrustUpdate._(
        presentedHostKey: presentedHostKey,
        mode: _TrustedHostUpdateMode.touch,
      );

  /// Creates an update that stores or replaces the trusted host key.
  factory PendingHostTrustUpdate.upsert(
    VerifiedHostKey presentedHostKey, {
    required bool resetFirstSeen,
  }) => PendingHostTrustUpdate._(
    presentedHostKey: presentedHostKey,
    mode: _TrustedHostUpdateMode.upsert,
    resetFirstSeen: resetFirstSeen,
  );

  final VerifiedHostKey _presentedHostKey;
  final _TrustedHostUpdateMode _mode;
  final bool _resetFirstSeen;

  /// Persists a newly accepted trust decision immediately.
  Future<void> persistTrustDecision(KnownHostsRepository repository) async {
    if (_mode != _TrustedHostUpdateMode.upsert) {
      return;
    }

    await repository.upsertTrustedHost(
      hostname: _presentedHostKey.hostname,
      port: _presentedHostKey.port,
      keyType: _presentedHostKey.keyType,
      fingerprint: _presentedHostKey.fingerprint,
      encodedHostKey: _presentedHostKey.encodedHostKey,
      resetFirstSeen: _resetFirstSeen,
    );
  }

  /// Updates `lastSeen` after authentication succeeds with a trusted key.
  Future<void> commitAfterAuthentication(
    KnownHostsRepository repository,
  ) async {
    if (_mode != _TrustedHostUpdateMode.touch) {
      return;
    }

    await repository.markTrustedHostSeen(
      hostname: _presentedHostKey.hostname,
      port: _presentedHostKey.port,
      keyType: _presentedHostKey.keyType,
      fingerprint: _presentedHostKey.fingerprint,
      encodedHostKey: _presentedHostKey.encodedHostKey,
    );
  }
}

/// Error thrown when SSH host-key verification fails.
class HostKeyVerificationException implements Exception {
  /// Creates a [HostKeyVerificationException].
  const HostKeyVerificationException(this.message);

  /// Human-readable reason for the failure.
  final String message;

  @override
  String toString() => message;
}

/// Verifies SSH host keys against the persisted known-hosts trust store.
class HostKeyVerificationService {
  /// Creates a [HostKeyVerificationService].
  const HostKeyVerificationService({
    required KnownHostsRepository knownHostsRepository,
    this.promptHandler,
  }) : _knownHostsRepository = knownHostsRepository;

  final KnownHostsRepository _knownHostsRepository;

  /// UI callback used for TOFU and changed-key prompts.
  final HostKeyPromptHandler? promptHandler;

  /// Verifies [presentedHostKey] and returns a deferred persistence update.
  Future<PendingHostTrustUpdate> verify(
    VerifiedHostKey presentedHostKey,
  ) async {
    final existingKnownHost = await _knownHostsRepository.getByHost(
      presentedHostKey.hostname,
      presentedHostKey.port,
    );

    if (existingKnownHost == null) {
      await _promptUnknownHost(presentedHostKey);
      return PendingHostTrustUpdate.upsert(
        presentedHostKey,
        resetFirstSeen: true,
      );
    }

    if (presentedHostKey.matches(existingKnownHost)) {
      return PendingHostTrustUpdate.touch(presentedHostKey);
    }

    await _promptChangedHost(presentedHostKey, existingKnownHost);
    return PendingHostTrustUpdate.upsert(
      presentedHostKey,
      resetFirstSeen: true,
    );
  }

  Future<void> _promptUnknownHost(VerifiedHostKey presentedHostKey) async {
    final handler = promptHandler;
    if (handler == null) {
      throw HostKeyVerificationException(
        'Host key verification is required for '
        '${presentedHostKey.hostLabel}, but no trust prompt is available.',
      );
    }

    final decision = await handler(
      HostKeyVerificationRequest(
        presentedHostKey: presentedHostKey,
        existingKnownHost: null,
      ),
    );
    if (decision != HostKeyTrustDecision.trust) {
      throw HostKeyVerificationException(
        'Connection cancelled because ${presentedHostKey.hostLabel} is not '
        'trusted yet.',
      );
    }
  }

  Future<void> _promptChangedHost(
    VerifiedHostKey presentedHostKey,
    KnownHost existingKnownHost,
  ) async {
    final handler = promptHandler;
    if (handler == null) {
      throw HostKeyVerificationException(
        'The trusted host key for ${presentedHostKey.hostLabel} changed, but '
        'the replacement prompt is not available.',
      );
    }

    final decision = await handler(
      HostKeyVerificationRequest(
        presentedHostKey: presentedHostKey,
        existingKnownHost: existingKnownHost,
      ),
    );
    if (decision != HostKeyTrustDecision.replace) {
      throw HostKeyVerificationException(
        'Connection cancelled because the trusted host key for '
        '${presentedHostKey.hostLabel} changed.',
      );
    }
  }
}

/// Formats the preferred SHA-256 SSH host-key fingerprint.
String formatSshHostKeyFingerprint(List<int> hostKeyBytes) {
  final digest = sha256.convert(hostKeyBytes).bytes;
  final encoded = base64.encode(digest).replaceAll('=', '');
  return 'SHA256:$encoded';
}

/// Formats the legacy MD5 SSH host-key fingerprint.
String formatLegacySshHostKeyFingerprint(List<int> hostKeyBytes) {
  final digest = md5.convert(hostKeyBytes).bytes;
  final buffer = StringBuffer();
  for (var i = 0; i < digest.length; i++) {
    if (i > 0) {
      buffer.write(':');
    }
    buffer.write(digest[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
