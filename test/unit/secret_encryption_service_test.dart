// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/security/secret_encryption_service.dart';

class _MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

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

    test('reuses and migrates the legacy master key entry', () async {
      final storage = _MockFlutterSecureStorage();
      final writes = <String, String>{};
      final legacyValue = base64Encode(
        List<int>.generate(32, (index) => index),
      );

      when(
        () => storage.read(key: 'flutty_db_encryption_key_v1'),
      ).thenAnswer((_) async => null);
      when(
        () => storage.read(key: 'flutty_db_secret_key_v1'),
      ).thenAnswer((_) async => legacyValue);
      when(
        () => storage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        ),
      ).thenAnswer((invocation) async {
        writes[invocation.namedArguments[#key] as String] =
            invocation.namedArguments[#value] as String;
      });

      service = SecretEncryptionService(storage: storage, random: Random(1));

      final encrypted = await service.encryptNullable('migrate-me');

      expect(encrypted, startsWith('ENCv1:'));
      expect(writes['flutty_db_encryption_key_v1'], legacyValue);
      verify(() => storage.read(key: 'flutty_db_encryption_key_v1')).called(1);
      verify(() => storage.read(key: 'flutty_db_secret_key_v1')).called(1);
      verify(
        () => storage.write(
          key: 'flutty_db_encryption_key_v1',
          value: legacyValue,
        ),
      ).called(1);
    });
  });
}
