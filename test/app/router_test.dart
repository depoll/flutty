// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/app/router.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';

void main() {
  group('redirectForAuthState', () {
    test('fails closed to lock while auth is still initializing', () {
      final redirect = redirectForAuthState(
        authState: AuthState.unknown,
        matchedLocation: '/',
      );

      expect(redirect, '/lock');
    });

    test('allows lock screen while auth is still initializing', () {
      final redirect = redirectForAuthState(
        authState: AuthState.unknown,
        matchedLocation: '/lock',
      );

      expect(redirect, isNull);
    });

    test('returns home when auth is not configured on lock screen', () {
      final redirect = redirectForAuthState(
        authState: AuthState.notConfigured,
        matchedLocation: '/lock',
      );

      expect(redirect, '/');
    });

    test('keeps auth setup accessible when auth is not configured', () {
      final redirect = redirectForAuthState(
        authState: AuthState.notConfigured,
        matchedLocation: '/auth-setup',
      );

      expect(redirect, isNull);
    });

    test('returns home when unlocked user visits lock screen', () {
      final redirect = redirectForAuthState(
        authState: AuthState.unlocked,
        matchedLocation: '/lock',
      );

      expect(redirect, '/');
    });
  });
}
