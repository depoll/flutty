import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/key_repository.dart';
import 'openssh_key_generator.dart';

/// Key type for SSH key generation.
enum SshKeyType {
  /// Ed25519 key (recommended).
  ed25519,

  /// RSA 2048-bit key.
  rsa2048,

  /// RSA 4096-bit key.
  rsa4096,
}

/// Service for SSH key management.
class KeyService {
  /// Creates a new [KeyService].
  KeyService(this._keyRepository);

  final KeyRepository _keyRepository;

  /// Import a key from PEM content.
  Future<SshKey?> importKey({
    required String name,
    required String privateKeyPem,
    String? passphrase,
  }) async {
    try {
      // Parse the key to validate and extract public key
      final keyPairs = passphrase != null && passphrase.isNotEmpty
          ? SSHKeyPair.fromPem(privateKeyPem, passphrase)
          : SSHKeyPair.fromPem(privateKeyPem);

      if (keyPairs.isEmpty) return null;

      final keyPair = keyPairs.first;
      // Convert public key to OpenSSH format: type + space + base64-encoded key
      final publicKeyBytes = keyPair.toPublicKey().encode();
      // The algorithm name embedded at the start of the public-key blob is the
      // canonical OpenSSH type token (e.g. 'ssh-rsa', 'ssh-ed25519') — the
      // value expected in authorized_keys. keyPair.type is a signature type
      // such as 'rsa-sha2-256', which is not a valid authorized_keys prefix.
      final keyType = _readPublicKeyAlgorithm(publicKeyBytes);
      final publicKey = '$keyType ${base64.encode(publicKeyBytes)}';
      final fingerprint = computeOpenSshPublicKeyFingerprint(publicKey);

      final id = await _keyRepository.insert(
        SshKeysCompanion.insert(
          name: name,
          keyType: keyType,
          publicKey: publicKey,
          privateKey: privateKeyPem,
          passphrase: Value(passphrase),
          fingerprint: Value(fingerprint),
        ),
      );

      return _keyRepository.getById(id);
    } on FormatException {
      return null;
    } on SSHError {
      // Malformed OpenSSH structure, or an encrypted key with a missing or
      // incorrect passphrase (SSHKeyDecryptError). Report as "unimportable"
      // so the UI shows its "invalid key / incorrect passphrase" message
      // instead of surfacing an uncaught error (SSHError is not an Exception).
      return null;
    }
  }

  /// Generate an SSH key pair in-process and store it.
  ///
  /// Works on every platform: the key is produced in pure Dart in the OpenSSH
  /// private-key format (optionally encrypted with [passphrase]), so no
  /// `ssh-keygen` binary is required on mobile.
  Future<SshKey?> generateKey({
    required String name,
    required SshKeyType keyType,
    String? passphrase,
  }) async {
    final normalizedPassphrase = (passphrase?.isEmpty ?? true)
        ? null
        : passphrase;

    final privateKeyPem = await generateOpenSshPrivateKeyPem(
      keyType: keyType,
      comment: name,
      passphrase: normalizedPassphrase,
    );

    return importKey(
      name: name,
      privateKeyPem: privateKeyPem,
      passphrase: normalizedPassphrase,
    );
  }

  /// Get a key by ID.
  Future<SshKey?> getById(int id) => _keyRepository.getById(id);

  /// Reads the algorithm name embedded at the start of an OpenSSH public-key
  /// blob (an SSH length-prefixed string), e.g. 'ssh-ed25519' or 'ssh-rsa'.
  String _readPublicKeyAlgorithm(List<int> publicKeyBlob) {
    if (publicKeyBlob.length < 4) return 'unknown';
    final length =
        (publicKeyBlob[0] << 24) |
        (publicKeyBlob[1] << 16) |
        (publicKeyBlob[2] << 8) |
        publicKeyBlob[3];
    if (length <= 0 || 4 + length > publicKeyBlob.length) return 'unknown';
    return ascii.decode(publicKeyBlob.sublist(4, 4 + length));
  }
}

/// Computes the OpenSSH SHA256 fingerprint for a public key string.
String computeOpenSshPublicKeyFingerprint(String publicKey) {
  final parts = publicKey.trim().split(RegExp(r'\s+'));
  if (parts.length < 2 || parts[1].isEmpty) {
    throw const FormatException('Invalid OpenSSH public key');
  }

  final publicKeyBlob = base64Decode(parts[1]);
  final digest = crypto.sha256.convert(publicKeyBlob).bytes;
  return 'SHA256:${base64Encode(digest).replaceAll('=', '')}';
}

/// Provider for [KeyService].
final keyServiceProvider = Provider<KeyService>(
  (ref) => KeyService(ref.watch(keyRepositoryProvider)),
);
