// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/security/secret_encryption_service.dart';

void main() {
  group('SecretEncryptionService', () {
    late SecretEncryptionService service;

    setUp(() {
      service = SecretEncryptionService.forTesting();
    });

    test('encrypt/decrypt roundtrip for plaintext', () async {
      const plaintext = 's3cret-value';
      final encrypted = await service.encryptNullable(plaintext);

      expect(encrypted, isNotNull);
      expect(encrypted, startsWith('ENCv1:'));
      expect(encrypted, isNot(plaintext));
      await expectLater(
        service.decryptNullable(encrypted),
        completion(plaintext),
      );
    });

    test('keeps already encrypted values unchanged', () async {
      const plaintext = 'already-encrypted-value';
      final encrypted = await service.encryptNullable(plaintext);
      final reencrypted = await service.encryptNullable(encrypted);

      expect(reencrypted, encrypted);
      await expectLater(
        service.decryptNullable(reencrypted),
        completion(plaintext),
      );
    });

    test('encrypts malformed ENCv1-prefixed plaintext', () async {
      const prefixedPlaintext = 'ENCv1:not-a-valid-envelope';
      final encrypted = await service.encryptNullable(prefixedPlaintext);

      expect(encrypted, isNot(prefixedPlaintext));
      expect(encrypted, startsWith('ENCv1:'));
      await expectLater(
        service.decryptNullable(encrypted),
        completion(prefixedPlaintext),
      );
    });
  });
}
