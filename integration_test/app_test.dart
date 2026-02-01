import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monkeyssh/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('App Integration Tests', () {
    testWidgets('Home screen loads and shows navigation options', (
      tester,
    ) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Verify home screen elements
      expect(find.text('Flutty'), findsOneWidget);
      expect(find.text('Quick Connect'), findsOneWidget);
      expect(find.text('Hosts'), findsOneWidget);
      expect(find.text('Keys'), findsOneWidget);
      expect(find.text('Snippets'), findsOneWidget);
      expect(find.text('Port Forward'), findsOneWidget);
    });

    testWidgets('Navigate to Hosts screen', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Tap on Hosts card
      await tester.tap(find.text('Hosts'));
      await tester.pumpAndSettle();

      // Verify hosts screen
      expect(find.text('Hosts'), findsOneWidget);
    });

    testWidgets('Navigate to Settings screen', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Tap on settings icon
      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      // Verify settings screen
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);
    });

    testWidgets('Navigate to Keys screen', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Tap on Keys card
      await tester.tap(find.text('Keys'));
      await tester.pumpAndSettle();

      // Verify keys screen
      expect(find.text('SSH Keys'), findsOneWidget);
    });

    testWidgets('Navigate to Snippets screen', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Tap on Snippets card
      await tester.tap(find.text('Snippets'));
      await tester.pumpAndSettle();

      // Verify snippets screen
      expect(find.text('Snippets'), findsOneWidget);
    });
  });
}
