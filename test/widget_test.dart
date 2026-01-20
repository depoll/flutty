// ignore_for_file: public_member_api_docs

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutty/app/app.dart';

// These tests are skipped because FluttyApp uses StreamProviders
// which don't settle in widget tests (continuous database watchers).
// See integration tests for full app testing.
void main() {
  testWidgets(
    'App renders home screen',
    skip: true, // StreamProvider tests hang - use integration tests instead
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: FluttyApp()));
      // Just pump initial frames, don't wait for settle
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Flutty'), findsOneWidget);
    },
  );

  testWidgets(
    'Navigation cards are tappable',
    skip: true, // StreamProvider tests hang - use integration tests instead
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: FluttyApp()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Find and tap the Hosts card
      final hostsCard = find.text('Hosts');
      expect(hostsCard, findsOneWidget);
      await tester.tap(hostsCard);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The navigation happened if we didn't crash
    },
  );
}
