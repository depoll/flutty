// ignore_for_file: public_member_api_docs, directives_ordering

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/domain/services/auth_service.dart';

class MockFlutterSecureStorage extends Mock implements FlutterSecureStorage {}

class MockLocalAuthentication extends Mock implements LocalAuthentication {}

void main() {
  late AuthService authService;
  late MockFlutterSecureStorage mockStorage;
  late MockLocalAuthentication mockLocalAuth;

  setUp(() {
    mockStorage = MockFlutterSecureStorage();
    mockLocalAuth = MockLocalAuthentication();
    authService = AuthService(storage: mockStorage, localAuth: mockLocalAuth);
  });

  group('AuthService', () {
    group('isAuthEnabled', () {
      test('returns false when not configured', () async {
        when(
          () => mockStorage.read(key: any(named: 'key')),
        ).thenAnswer((_) async => null);

        final result = await authService.isAuthEnabled();

        expect(result, false);
      });

      test('returns true when configured', () async {
        when(
          () => mockStorage.read(key: 'flutty_auth_enabled'),
        ).thenAnswer((_) async => 'true');

        final result = await authService.isAuthEnabled();

        expect(result, true);
      });
    });

    group('setupPin', () {
      test('stores hashed PIN and enables auth', () async {
        when(
          () => mockStorage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((_) async {});

        await authService.setupPin('1234');

        verify(
          () => mockStorage.write(
            key: 'flutty_pin_hash',
            value: any(named: 'value'),
          ),
        ).called(1);
        verify(
          () => mockStorage.write(key: 'flutty_auth_enabled', value: 'true'),
        ).called(1);
      });
    });

    group('verifyPin', () {
      test('returns true for correct PIN', () async {
        // First set up a PIN
        String? storedHash;
        when(
          () => mockStorage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((invocation) async {
          if (invocation.namedArguments[const Symbol('key')] ==
              'flutty_pin_hash') {
            storedHash =
                invocation.namedArguments[const Symbol('value')] as String?;
          }
        });

        await authService.setupPin('1234');

        when(
          () => mockStorage.read(key: 'flutty_pin_hash'),
        ).thenAnswer((_) async => storedHash);

        final result = await authService.verifyPin('1234');

        expect(result, true);
      });

      test('returns false for incorrect PIN', () async {
        String? storedHash;
        when(
          () => mockStorage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((invocation) async {
          if (invocation.namedArguments[const Symbol('key')] ==
              'flutty_pin_hash') {
            storedHash =
                invocation.namedArguments[const Symbol('value')] as String?;
          }
        });

        await authService.setupPin('1234');

        when(
          () => mockStorage.read(key: 'flutty_pin_hash'),
        ).thenAnswer((_) async => storedHash);

        final result = await authService.verifyPin('9999');

        expect(result, false);
      });

      test('returns false when no PIN is set', () async {
        when(
          () => mockStorage.read(key: 'flutty_pin_hash'),
        ).thenAnswer((_) async => null);

        final result = await authService.verifyPin('1234');

        expect(result, false);
      });
    });

    group('isBiometricAvailable', () {
      test('returns true when biometrics available', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => true);
        when(
          () => mockLocalAuth.getAvailableBiometrics(),
        ).thenAnswer((_) async => [BiometricType.fingerprint]);

        final result = await authService.isBiometricAvailable();

        expect(result, true);
      });

      test('returns false when no biometrics', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => true);
        when(
          () => mockLocalAuth.getAvailableBiometrics(),
        ).thenAnswer((_) async => []);

        final result = await authService.isBiometricAvailable();

        expect(result, false);
      });

      test('returns false when device cannot check biometrics', () async {
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => false);

        final result = await authService.isBiometricAvailable();

        expect(result, false);
      });
    });

    group('getAuthMethod', () {
      test('returns none when auth not enabled', () async {
        when(
          () => mockStorage.read(key: 'flutty_auth_enabled'),
        ).thenAnswer((_) async => null);

        final result = await authService.getAuthMethod();

        expect(result, AuthMethod.none);
      });

      test('returns pin when only PIN is configured', () async {
        when(
          () => mockStorage.read(key: 'flutty_auth_enabled'),
        ).thenAnswer((_) async => 'true');
        when(
          () => mockStorage.read(key: 'flutty_biometric_enabled'),
        ).thenAnswer((_) async => null);
        when(
          () => mockStorage.read(key: 'flutty_pin_hash'),
        ).thenAnswer((_) async => 'somehash');
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => false);

        final result = await authService.getAuthMethod();

        expect(result, AuthMethod.pin);
      });

      test('returns both when PIN and biometric enabled', () async {
        when(
          () => mockStorage.read(key: 'flutty_auth_enabled'),
        ).thenAnswer((_) async => 'true');
        when(
          () => mockStorage.read(key: 'flutty_biometric_enabled'),
        ).thenAnswer((_) async => 'true');
        when(
          () => mockStorage.read(key: 'flutty_pin_hash'),
        ).thenAnswer((_) async => 'somehash');
        when(
          () => mockLocalAuth.canCheckBiometrics,
        ).thenAnswer((_) async => true);
        when(
          () => mockLocalAuth.getAvailableBiometrics(),
        ).thenAnswer((_) async => [BiometricType.fingerprint]);

        final result = await authService.getAuthMethod();

        expect(result, AuthMethod.both);
      });
    });

    group('disableAuth', () {
      test('clears all auth data', () async {
        when(
          () => mockStorage.delete(key: any(named: 'key')),
        ).thenAnswer((_) async {});

        await authService.disableAuth();

        verify(() => mockStorage.delete(key: 'flutty_pin_hash')).called(1);
        verify(() => mockStorage.delete(key: 'flutty_auth_enabled')).called(1);
        verify(
          () => mockStorage.delete(key: 'flutty_biometric_enabled'),
        ).called(1);
      });
    });

    group('changePin', () {
      test('changes PIN when current PIN is correct', () async {
        String? storedHash;
        when(
          () => mockStorage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ),
        ).thenAnswer((invocation) async {
          if (invocation.namedArguments[const Symbol('key')] ==
              'flutty_pin_hash') {
            storedHash =
                invocation.namedArguments[const Symbol('value')] as String?;
          }
        });

        await authService.setupPin('1234');

        when(
          () => mockStorage.read(key: 'flutty_pin_hash'),
        ).thenAnswer((_) async => storedHash);

        final result = await authService.changePin('1234', '5678');

        expect(result, true);
      });

      test('fails when current PIN is incorrect', () async {
        when(
          () => mockStorage.read(key: 'flutty_pin_hash'),
        ).thenAnswer((_) async => 'wronghash');

        final result = await authService.changePin('1234', '5678');

        expect(result, false);
      });
    });
  });
}
