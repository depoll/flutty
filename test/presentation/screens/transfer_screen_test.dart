import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/screens/transfer_screen.dart';

class _MockAuthService extends Mock implements AuthService {}

class _UnlockedAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.unlocked;
}

void main() {
  late _MockAuthService authService;
  late ProviderContainer container;
  late BuildContext context;

  setUp(() {
    authService = _MockAuthService();
    container = ProviderContainer(
      overrides: [
        authStateProvider.overrideWith(_UnlockedAuthStateNotifier.new),
      ],
    );
  });

  tearDown(() {
    container.dispose();
  });

  group('sanitizeTransferFileBaseName', () {
    test('replaces reserved filename characters and whitespace', () {
      expect(
        sanitizeTransferFileBaseName('host: prod/app? key*'),
        'host-prod-app-key',
      );
    });

    test('falls back when the suggestion is empty after sanitizing', () {
      expect(
        sanitizeTransferFileBaseName(r'  <>:"/\|?*  '),
        'monkeyssh-transfer',
      );
    });

    test('strips leading and trailing dots and separators', () {
      expect(sanitizeTransferFileBaseName('.. key export ..'), 'key-export');
    });
  });

  testWidgets(
    'fails closed when the app re-locks during biometric transfer auth',
    (tester) async {
      when(() => authService.isAuthEnabled()).thenAnswer((_) async => true);
      when(
        () => authService.getAuthMethod(),
      ).thenAnswer((_) async => AuthMethod.biometric);
      when(
        () => authService.authenticateWithBiometrics(
          reason: any(named: 'reason'),
        ),
      ).thenAnswer((_) async {
        container.read(authStateProvider.notifier).lockForAutoLock();
        return true;
      });

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Builder(
              builder: (buildContext) {
                context = buildContext;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      final result = await authorizeSensitiveTransferExport(
        context: context,
        authService: authService,
        reason: 'Authenticate to export migration package',
      );

      expect(result, isFalse);
      expect(container.read(authStateProvider), AuthState.locked);
    },
  );
}
