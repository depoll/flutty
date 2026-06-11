import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/main.dart' as app;

Finder _desktopNavItem(String label) => find.widgetWithText(InkWell, label);
Future<void> _launchDesktopApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1400, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App Integration Tests', () {
    testWidgets('Home screen loads and shows navigation options', (
      tester,
    ) async {
      await _launchDesktopApp(tester);

      // Verify home screen elements
      expect(find.text('MonkeySSH'), findsOneWidget);
      expect(_desktopNavItem('Hosts'), findsOneWidget);
      expect(_desktopNavItem('Connections'), findsOneWidget);
      expect(_desktopNavItem('Keys'), findsOneWidget);
      expect(_desktopNavItem('Snippets'), findsOneWidget);
      expect(_desktopNavItem('Settings'), findsOneWidget);
      expect(find.text('New Host'), findsOneWidget);
    });

    testWidgets('Navigate to Hosts screen', (tester) async {
      await _launchDesktopApp(tester);

      // Tap on Hosts card
      await tester.tap(_desktopNavItem('Hosts'));
      await tester.pumpAndSettle();

      // Verify hosts screen
      expect(find.text('New Host'), findsOneWidget);
    });

    testWidgets('Navigate to Settings screen', (tester) async {
      await _launchDesktopApp(tester);

      // Tap on settings navigation item
      await tester.tap(_desktopNavItem('Settings'));
      await tester.pumpAndSettle();

      // Verify settings screen
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);
    });

    testWidgets('Navigate to Keys screen', (tester) async {
      await _launchDesktopApp(tester);

      // Tap on Keys card
      await tester.tap(_desktopNavItem('Keys'));
      await tester.pumpAndSettle();

      // Verify keys screen
      expect(find.text('SSH Keys'), findsOneWidget);
      expect(find.text('Add Key'), findsOneWidget);
    });

    testWidgets('Navigate to Snippets screen', (tester) async {
      await _launchDesktopApp(tester);

      // Tap on Snippets card
      await tester.tap(_desktopNavItem('Snippets'));
      await tester.pumpAndSettle();

      // Verify snippets screen
      expect(find.text('Snippets'), findsOneWidget);
      expect(find.text('Add Snippet'), findsOneWidget);
    });
  });
}
