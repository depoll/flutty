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
  final typeBytes = utf8.encode('ssh-ed25519');
  final writer = BytesBuilder(copy: false)
    ..add(_uint32(typeBytes.length))
    ..add(typeBytes)
    ..add(_uint32(keyData.length))
    ..add(keyData);
  return writer.takeBytes();
}

Uint8List _uint32(int value) => Uint8List.fromList([
  (value >> 24) & 0xFF,
  (value >> 16) & 0xFF,
  (value >> 8) & 0xFF,
  value & 0xFF,
]);
