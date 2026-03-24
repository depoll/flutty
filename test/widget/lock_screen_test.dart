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

    testWidgets(
      'retry refreshes auth state when storage recovers without auth configured',
      (tester) async {
        final authService = _MockAuthService();
        final container = ProviderContainer(
          overrides: [authServiceProvider.overrideWithValue(authService)],
        );
        final reportedErrors = <FlutterErrorDetails>[];
        final originalOnError = FlutterError.onError;
        addTearDown(container.dispose);
        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = originalOnError);

        var authEnabledCalls = 0;
        when(authService.isAuthEnabled).thenAnswer((_) async {
          if (authEnabledCalls++ == 0) {
            throw Exception('storage unavailable');
          }
          return false;
        });

        var authMethodCalls = 0;
        when(authService.getAuthMethod).thenAnswer((_) async {
          if (authMethodCalls++ == 0) {
            throw Exception('secure storage unavailable');
          }
          return AuthMethod.none;
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: LockScreen()),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.locked);
        expect(find.text('Retry'), findsOneWidget);
        expect(reportedErrors, hasLength(2));

        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.notConfigured);
        expect(find.text('Retry'), findsNothing);
        expect(reportedErrors, hasLength(2));
      },
    );

    testWidgets(
      'keeps retry UI when auth method recovers to none but refresh stays locked',
      (tester) async {
        final authService = _MockAuthService();
        final container = ProviderContainer(
          overrides: [authServiceProvider.overrideWithValue(authService)],
        );
        final reportedErrors = <FlutterErrorDetails>[];
        final originalOnError = FlutterError.onError;
        addTearDown(container.dispose);
        FlutterError.onError = reportedErrors.add;
        addTearDown(() => FlutterError.onError = originalOnError);

        when(authService.isAuthEnabled).thenAnswer((_) async {
          throw Exception('storage unavailable');
        });

        var authMethodCalls = 0;
        when(authService.getAuthMethod).thenAnswer((_) async {
          if (authMethodCalls++ == 0) {
            throw Exception('secure storage unavailable');
          }
          return AuthMethod.none;
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: LockScreen()),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.locked);
        expect(find.text('Retry'), findsOneWidget);
        expect(reportedErrors, hasLength(2));

        await tester.tap(find.text('Retry'));
        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.locked);
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.text(
            'Secure storage is unavailable. The app will stay locked until authentication is ready.',
          ),
          findsOneWidget,
        );
        expect(find.text('Unlock'), findsNothing);
        expect(find.text('Use biometrics'), findsNothing);
        expect(reportedErrors, hasLength(3));
      },
    );

    testWidgets(
      'shows retry UI on initial load when state is locked without an auth method',
      (tester) async {
        final authService = _MockAuthService();
        final container = ProviderContainer(
          overrides: [authServiceProvider.overrideWithValue(authService)],
        );
        addTearDown(container.dispose);

        when(authService.isAuthEnabled).thenAnswer((_) async => true);
        when(
          authService.getAuthMethod,
        ).thenAnswer((_) async => AuthMethod.none);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: LockScreen()),
          ),
        );

        await tester.pump();
        await tester.pump();

        expect(container.read(authStateProvider), AuthState.locked);
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.text(
            'Secure storage is unavailable. The app will stay locked until authentication is ready.',
          ),
          findsOneWidget,
        );
        expect(find.text('Unlock'), findsNothing);
        expect(find.text('Use biometrics'), findsNothing);
      },
    );
  });
}
