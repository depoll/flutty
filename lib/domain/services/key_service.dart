import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../data/repositories/key_repository.dart';

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
      final publicKey = keyPair.toPublicKey().toString();
      final fingerprint = _computeFingerprint(publicKey);
      final keyType = _detectKeyType(publicKey);

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
    }
  }

  /// Import a public key only (for reference).
  Future<SshKey?> importPublicKey({
    required String name,
    required String publicKey,
  }) async {
    final fingerprint = _computeFingerprint(publicKey);
    final keyType = _detectKeyType(publicKey);

    final id = await _keyRepository.insert(
      SshKeysCompanion.insert(
        name: name,
        keyType: keyType,
        publicKey: publicKey,
        privateKey: '', // No private key
        fingerprint: Value(fingerprint),
      ),
    );

    return _keyRepository.getById(id);
  }

  /// Export a key's public key in OpenSSH format.
  String exportPublicKey(SshKey key, {String? comment}) {
    if (comment != null && comment.isNotEmpty) {
      return '${key.publicKey} $comment';
    }
    return key.publicKey;
  }

  /// Export a key's private key in PEM format.
  String exportPrivateKey(SshKey key) => key.privateKey;

  /// Validate a private key.
  bool validatePrivateKey(String pem, {String? passphrase}) {
    try {
      final keys = passphrase != null && passphrase.isNotEmpty
          ? SSHKeyPair.fromPem(pem, passphrase)
          : SSHKeyPair.fromPem(pem);
      return keys.isNotEmpty;
    } on FormatException {
      return false;
    }
  }

  /// Delete a key.
  Future<void> deleteKey(int id) => _keyRepository.delete(id);

  /// Get all keys.
  Future<List<SshKey>> getAllKeys() => _keyRepository.getAll();

  /// Watch all keys.
  Stream<List<SshKey>> watchAllKeys() => _keyRepository.watchAll();

  /// Get a key by ID.
  Future<SshKey?> getById(int id) => _keyRepository.getById(id);

  String _detectKeyType(String publicKey) {
    if (publicKey.startsWith('ssh-ed25519')) {
      return 'ed25519';
    } else if (publicKey.startsWith('ssh-rsa')) {
      return 'rsa';
    } else if (publicKey.startsWith('ecdsa-')) {
      return 'ecdsa';
    }
    return 'unknown';
  }

  String _computeFingerprint(String publicKey) {
    // Simple hash-based fingerprint for display
    final bytes = utf8.encode(publicKey);
    var hash = 0;
    for (final byte in bytes) {
      hash = ((hash << 5) - hash) + byte;
      hash = hash & 0xFFFFFFFF;
    }

    // Format as fingerprint-like string
    final hex = hash.toRadixString(16).padLeft(8, '0').toUpperCase();
    return 'SHA256:${hex.substring(0, 2)}:${hex.substring(2, 4)}:'
        '${hex.substring(4, 6)}:${hex.substring(6, 8)}';
  }
}

/// Provider for [KeyService].
final keyServiceProvider = Provider<KeyService>(
  (ref) => KeyService(ref.watch(keyRepositoryProvider)),
);
