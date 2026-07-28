// ignore_for_file: public_member_api_docs

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/host_repository.dart';
import 'package:monkeyssh/data/repositories/key_repository.dart';
import 'package:monkeyssh/data/security/secret_encryption_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';

class _CapturingSshService extends SshService {
  _CapturingSshService({
    required super.hostRepository,
    required super.keyRepository,
  });

  SshConnectionConfig? capturedConfig;

  @override
  Future<SshConnectionResult> connect(
    SshConnectionConfig config, {
    ConnectionProgressCallback? onProgress,
    bool isJumpHost = false,
    SshConnectionCancellationToken? cancellationToken,
  }) async {
    capturedConfig = config;
    return const SshConnectionResult(success: false, error: 'stubbed');
  }
}

String _structurallyValidInvalidEncryptedSecret() {
  final envelope = {
    'n': base64Url.encode(List<int>.filled(12, 1)),
    'c': base64Url.encode([1, 2, 3]),
    'm': base64Url.encode(List<int>.filled(16, 2)),
  };
  return 'ENCv1:${base64Url.encode(utf8.encode(jsonEncode(envelope)))}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'connection setup skips unreadable Auto keys before opening SSH',
    (_) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final encryptionService = SecretEncryptionService.forTesting();
      final hostRepository = HostRepository(db, encryptionService);
      final keyRepository = KeyRepository(db, encryptionService);
      final sshService = _CapturingSshService(
        hostRepository: hostRepository,
        keyRepository: keyRepository,
      );

      await db
          .into(db.sshKeys)
          .insert(
            SshKeysCompanion.insert(
              name: 'Unreadable Auto Key',
              keyType: 'ed25519',
              publicKey: 'ssh-ed25519 BAD',
              privateKey: _structurallyValidInvalidEncryptedSecret(),
            ),
          );
      await keyRepository.insert(
        SshKeysCompanion.insert(
          name: 'Readable Auto Key',
          keyType: 'ed25519',
          publicKey: 'ssh-ed25519 GOOD',
          privateKey: 'readable-key-material',
        ),
      );
      final hostId = await db
          .into(db.hosts)
          .insert(
            HostsCompanion.insert(
              label: 'Auto Host',
              hostname: '127.0.0.1',
              username: 'admin',
            ),
          );

      final result = await sshService.connectToHost(hostId);

      expect(result.success, isFalse);
      expect(result.error, 'stubbed');
      expect(sshService.capturedConfig, isNotNull);
      expect(sshService.capturedConfig!.identityKeys, hasLength(1));
      expect(
        sshService.capturedConfig!.identityKeys!.single.name,
        'Readable Auto Key',
      );
    },
  );
}
