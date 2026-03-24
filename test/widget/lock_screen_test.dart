// ignore_for_file: public_member_api_docs, directives_ordering

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/screens/lock_screen.dart';

class _MockAuthService extends Mock implements AuthService {}

class _LockedAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.locked;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LockScreen', () {
    testWidgets('stays fail-closed when auth method lookup throws', (
      tester,
    ) async {
      final authService = _MockAuthService();
      final reportedErrors = <FlutterErrorDetails>[];
      final originalOnError = FlutterError.onError;

      FlutterError.onError = reportedErrors.add;
      addTearDown(() => FlutterError.onError = originalOnError);

      when(
        authService.getAuthMethod,
      ).thenThrow(Exception('secure storage unavailable'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authServiceProvider.overrideWithValue(authService),
            authStateProvider.overrideWith(_LockedAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: LockScreen()),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(reportedErrors, hasLength(1));
      expect(find.text('Retry'), findsOneWidget);
      expect(
        find.text(
          'Secure storage is unavailable. The app will stay locked until authentication is ready.',
        ),
        findsOneWidget,
      );
      expect(find.text('Unlock'), findsNothing);
      expect(find.text('Use biometrics'), findsNothing);
    });
  });
}
