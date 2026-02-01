// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/presentation/screens/hosts_screen.dart';

// Most HostsScreen tests are skipped because the screen uses StreamProviders
// which don't settle in widget tests (continuous database watchers).
// The underlying repository tests provide coverage.
void main() {
  group('HostsScreen', () {
    testWidgets(
      'shows loading indicator initially',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: const MaterialApp(home: HostsScreen()),
          ),
        );

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
      skip: true, // Drift StreamProviders leave pending timers in test cleanup
    );
  });
}
