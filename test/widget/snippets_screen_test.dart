// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutty/presentation/screens/snippets_screen.dart';

// Most SnippetsScreen tests are skipped because the screen uses StreamProviders
// which don't settle in widget tests (continuous database watchers).
// The underlying repository tests provide coverage.
void main() {
  group('SnippetsScreen', () {
    testWidgets('shows loading indicator initially', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: SnippetsScreen())),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
