import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/main.dart' as app;

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(step);
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  fail('Timed out waiting for ${finder.describeMatch(Plurality.many)}');
}

Future<void> _launchApp(WidgetTester tester) async {
  app.main();
  await _pumpUntilFound(tester, find.byIcon(Icons.settings_outlined));
}

Future<void> _waitForUnlockedApp(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  final biometricButton = find.widgetWithText(TextButton, 'Use biometrics');
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 500));
    if (find.text('Change PIN').evaluate().isNotEmpty) {
      return;
    }
    if (find.byIcon(Icons.settings_outlined).evaluate().isNotEmpty &&
        find.text('Settings').evaluate().isEmpty) {
      return;
    }
    if (biometricButton.evaluate().isNotEmpty) {
      await tester.tap(biometricButton, warnIfMissed: false);
      await tester.pump();
    }
  }
  fail('Timed out waiting for biometric unlock to return to the home screen');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('security setup enables biometric unlock end to end', (
    tester,
  ) async {
    await _launchApp(tester);

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.text('Set up app lock'));

    await tester.tap(find.text('Set up app lock'));
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.text('Security Setup'));

    await tester.tap(find.text('PIN Code'));
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.text('Create PIN'));

    await tester.enterText(find.byType(TextField).first, '1234');
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Next'));
    await tester.pumpAndSettle();
    await _pumpUntilFound(tester, find.text('Confirm PIN'));

    await tester.enterText(find.byType(TextField).first, '1234');
    await tester.pump();
    await _pumpUntilFound(tester, find.text('Enable biometrics'));
    await tester.tap(find.text('Enable biometrics'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Complete'));
    await tester.pump();

    await _waitForUnlockedApp(tester);

    if (find.text('Change PIN').evaluate().isEmpty) {
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
    }
    await _pumpUntilFound(tester, find.text('Change PIN'));

    expect(find.text('Change PIN'), findsOneWidget);
    expect(find.text('Biometric authentication'), findsOneWidget);
  });
}
