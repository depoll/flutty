import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/screens/auth_setup_screen.dart';

class _BiometricAvailableAuthService extends AuthService {
  @override
  Future<bool> isBiometricSupported() async => true;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [
    BiometricType.fingerprint,
  ];
}

class _BiometricSupportedAuthService extends AuthService {
  @override
  Future<bool> isBiometricSupported() async => true;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async => [];
}

void main() {
  testWidgets('enables Next after entering a valid PIN', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(
            _BiometricAvailableAuthService(),
          ),
        ],
        child: const MaterialApp(home: AuthSetupScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('PIN Code'));
    await tester.pumpAndSettle();

    final nextButton = find.widgetWithText(ElevatedButton, 'Next');
    expect(tester.widget<ElevatedButton>(nextButton).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, '1234');
    await tester.pump();

    expect(tester.widget<ElevatedButton>(nextButton).onPressed, isNotNull);
  });

  testWidgets(
    'shows biometric opt-in when biometrics are supported but not enrolled',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authServiceProvider.overrideWithValue(
              _BiometricSupportedAuthService(),
            ),
          ],
          child: const MaterialApp(home: AuthSetupScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Biometrics'), findsOneWidget);
      expect(
        find.text(
          'Enable now, then enroll fingerprint or face before first use',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('PIN Code'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '1234');
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Next'));
      await tester.pumpAndSettle();

      expect(find.text('Enable biometrics'), findsOneWidget);
      expect(
        find.text(
          'Enable now, then enroll fingerprint or face before first use',
        ),
        findsOneWidget,
      );
    },
  );
}
