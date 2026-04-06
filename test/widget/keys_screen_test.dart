// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/presentation/providers/entity_list_providers.dart';
import 'package:monkeyssh/presentation/screens/keys_screen.dart';

// Most KeysScreen tests are skipped because the screen uses StreamProviders
// which don't settle in widget tests (continuous database watchers).
// The underlying repository tests provide coverage.
void main() {
  group('KeysScreen', () {
    testWidgets(
      'shows loading indicator initially',
      (tester) async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [databaseProvider.overrideWithValue(db)],
            child: const MaterialApp(home: KeysScreen()),
          ),
        );

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
      skip: true, // Drift StreamProviders leave pending timers in test cleanup
    );
  });

  group('private key clipboard gating', () {
    final testKey = SshKey(
      id: 1,
      name: 'My Ed25519 Key',
      keyType: 'ed25519',
      publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5',
      privateKey: '-----BEGIN OPENSSH PRIVATE KEY-----\ntest-private-key-material\n-----END OPENSSH PRIVATE KEY-----',
      fingerprint: 'SHA256:AB:CD:EF:01',
      createdAt: DateTime(2026),
    );

    Widget _buildScreen() => ProviderScope(
      overrides: [
        allKeysProvider.overrideWith(
          (ref) => Stream.value([testKey]),
        ),
      ],
      child: const MaterialApp(home: KeysScreen()),
    );

    testWidgets(
      'private key is hidden by default when the details sheet opens',
      (tester) async {
        await tester.pumpWidget(_buildScreen());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.tap(find.text('My Ed25519 Key'));
        await tester.pumpAndSettle();

        expect(
          find.text('Private key hidden. Tap "Reveal Private Key" to view.'),
          findsOneWidget,
        );
        expect(find.text('Copy Private Key'), findsNothing);
      },
    );

    testWidgets(
      'Copy Private Key button only appears after the user explicitly reveals '
      'the private key',
      (tester) async {
        await tester.pumpWidget(_buildScreen());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.tap(find.text('My Ed25519 Key'));
        await tester.pumpAndSettle();

        expect(find.text('Copy Private Key'), findsNothing);

        await tester.tap(find.text('Reveal Private Key'));
        await tester.pumpAndSettle();

        expect(find.text('Copy Private Key'), findsOneWidget);
      },
    );

    testWidgets(
      'canceling the confirmation dialog does not copy the private key to the '
      'clipboard',
      (tester) async {
        await tester.pumpWidget(_buildScreen());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.tap(find.text('My Ed25519 Key'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Reveal Private Key'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Copy Private Key'));
        await tester.pumpAndSettle();

        expect(find.text('Copy private key?'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        // No copy happened: the "Copied to clipboard" snackbar must not appear.
        expect(find.text('Copied to clipboard'), findsNothing);
      },
    );

    testWidgets(
      'confirming the dialog copies the private key to the clipboard',
      (tester) async {
        await tester.pumpWidget(_buildScreen());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        await tester.tap(find.text('My Ed25519 Key'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Reveal Private Key'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Copy Private Key'));
        await tester.pumpAndSettle();

        expect(find.text('Copy private key?'), findsOneWidget);
        expect(
          find.textContaining('Private keys are sensitive'),
          findsOneWidget,
        );

        await tester.tap(find.text('Copy'));
        await tester.pumpAndSettle();

        // Copy happened: the snackbar confirms the action.
        expect(find.text('Copied to clipboard'), findsOneWidget);
      },
    );
  });
}
