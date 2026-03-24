// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/known_hosts_repository.dart';
import 'package:monkeyssh/domain/services/host_key_verification.dart';

void main() {
  late AppDatabase db;
  late KnownHostsRepository repository;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repository = KnownHostsRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  group('HostKeyVerificationService', () {
    test('accepts and persists an unknown host after TOFU trust', () async {
      final service = HostKeyVerificationService(
        knownHostsRepository: repository,
        promptHandler: (_) async => HostKeyTrustDecision.trust,
      );
      final presentedHostKey = _verifiedHostKey('new.example.com', 22, [
        1,
        2,
        3,
      ]);

      final update = await service.verify(presentedHostKey);
      await update.persistTrustDecision(repository);

      final storedHost = await repository.getByHost('new.example.com', 22);
      expect(storedHost, isNotNull);
      expect(storedHost!.hostKey, presentedHostKey.encodedHostKey);
      expect(storedHost.fingerprint, presentedHostKey.fingerprint);
    });

    test('rejects changed host keys by default', () async {
      final originalHostKey = _verifiedHostKey('change.example.com', 22, [
        4,
        5,
        6,
      ]);
      await repository.upsertTrustedHost(
        hostname: originalHostKey.hostname,
        port: originalHostKey.port,
        keyType: originalHostKey.keyType,
        fingerprint: originalHostKey.fingerprint,
        encodedHostKey: originalHostKey.encodedHostKey,
        resetFirstSeen: true,
      );
      final service = HostKeyVerificationService(
        knownHostsRepository: repository,
        promptHandler: (_) async => HostKeyTrustDecision.reject,
      );
      final presentedHostKey = _verifiedHostKey('change.example.com', 22, [
        7,
        8,
        9,
      ]);

      await expectLater(
        service.verify(presentedHostKey),
        throwsA(
          isA<HostKeyVerificationException>().having(
            (error) => error.message,
            'message',
            contains('changed'),
          ),
        ),
      );
    });

    test('allows explicit replacement of a changed trusted host key', () async {
      final originalHostKey = _verifiedHostKey('replace.example.com', 22, [
        4,
        5,
        6,
      ]);
      await repository.upsertTrustedHost(
        hostname: originalHostKey.hostname,
        port: originalHostKey.port,
        keyType: originalHostKey.keyType,
        fingerprint: originalHostKey.fingerprint,
        encodedHostKey: originalHostKey.encodedHostKey,
        resetFirstSeen: true,
      );
      final service = HostKeyVerificationService(
        knownHostsRepository: repository,
        promptHandler: (request) async {
          expect(request.existingKnownHost, isNotNull);
          expect(
            request.existingKnownHost!.hostKey,
            originalHostKey.encodedHostKey,
          );
          return HostKeyTrustDecision.replace;
        },
      );
      final replacementHostKey = _verifiedHostKey('replace.example.com', 22, [
        7,
        8,
        9,
      ]);

      final update = await service.verify(replacementHostKey);
      await update.persistTrustDecision(repository);

      final storedHost = await repository.getByHost('replace.example.com', 22);
      expect(storedHost, isNotNull);
      expect(storedHost!.hostKey, replacementHostKey.encodedHostKey);
      expect(storedHost.fingerprint, replacementHostKey.fingerprint);
    });

    test('accepts RSA host keys across signature algorithm variants', () async {
      final storedHostKey = _rsaVerifiedHostKey(
        'rsa.example.com',
        22,
        exponent: const [1, 0, 1],
        modulus: const [1, 2, 3, 4, 5, 6, 7, 8],
        keyType: 'rsa-sha2-256',
      );
      await repository.upsertTrustedHost(
        hostname: storedHostKey.hostname,
        port: storedHostKey.port,
        keyType: storedHostKey.keyType,
        fingerprint: storedHostKey.fingerprint,
        encodedHostKey: storedHostKey.encodedHostKey,
        resetFirstSeen: true,
      );

      var prompted = false;
      final service = HostKeyVerificationService(
        knownHostsRepository: repository,
        promptHandler: (_) async {
          prompted = true;
          return HostKeyTrustDecision.replace;
        },
      );
      final presentedHostKey = _rsaVerifiedHostKey(
        'rsa.example.com',
        22,
        exponent: const [1, 0, 1],
        modulus: const [1, 2, 3, 4, 5, 6, 7, 8],
        keyType: 'rsa-sha2-512',
      );

      final update = await service.verify(presentedHostKey);
      await update.commitAfterAuthentication(repository);

      final storedHost = await repository.getByHost('rsa.example.com', 22);
      expect(prompted, isFalse);
      expect(storedHost, isNotNull);
      expect(storedHost!.hostKey, presentedHostKey.encodedHostKey);
      expect(storedHost.fingerprint, presentedHostKey.fingerprint);
      expect(storedHost.keyType, 'ssh-rsa');
    });
  });
}

VerifiedHostKey _verifiedHostKey(
  String hostname,
  int port,
  List<int> keyData,
) => VerifiedHostKey(
  hostname: hostname,
  port: port,
  keyType: 'ssh-ed25519',
  hostKeyBytes: _ed25519HostKeyBlob(keyData),
);

Uint8List _ed25519HostKeyBlob(List<int> keyData) {
  final writer = BytesBuilder(copy: false)
    ..add(_sshString(utf8.encode('ssh-ed25519')))
    ..add(_sshString(keyData));
  return writer.takeBytes();
}

VerifiedHostKey _rsaVerifiedHostKey(
  String hostname,
  int port, {
  required List<int> exponent,
  required List<int> modulus,
  String keyType = 'ssh-rsa',
}) => VerifiedHostKey(
  hostname: hostname,
  port: port,
  keyType: keyType,
  hostKeyBytes: _rsaHostKeyBlob(exponent: exponent, modulus: modulus),
);

Uint8List _rsaHostKeyBlob({
  required List<int> exponent,
  required List<int> modulus,
}) {
  final writer = BytesBuilder(copy: false)
    ..add(_sshString(utf8.encode('ssh-rsa')))
    ..add(_mpInt(exponent))
    ..add(_mpInt(modulus));
  return writer.takeBytes();
}

Uint8List _mpInt(List<int> bytes) {
  final normalizedBytes = bytes.isNotEmpty && bytes.first >= 0x80
      ? <int>[0, ...bytes]
      : bytes;
  return _sshString(normalizedBytes);
}

Uint8List _sshString(List<int> bytes) =>
    Uint8List.fromList([..._uint32(bytes.length), ...bytes]);

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);
