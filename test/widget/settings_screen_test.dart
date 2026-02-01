// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/domain/services/auth_service.dart';
import 'package:monkeyssh/presentation/screens/settings_screen.dart';

void main() {
  group('SettingsScreen', () {
    testWidgets('displays all sections', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Appearance'), findsOneWidget);
      expect(find.text('Security'), findsOneWidget);
      expect(find.text('Terminal'), findsOneWidget);

      // Scroll to find About section
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('displays theme option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Theme'), findsOneWidget);
      expect(find.text('System default'), findsOneWidget);
    });

    testWidgets('displays font size option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Font size'), findsOneWidget);
      expect(find.text('14 pt'), findsOneWidget);
    });

    testWidgets('displays font family option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Font family'), findsOneWidget);
      expect(find.text('System Monospace'), findsOneWidget);
    });

    testWidgets('displays cursor style option', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Cursor style'), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
    });

    testWidgets('displays bell sound toggle', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Bell sound'), findsOneWidget);
      expect(find.text('Play sound on terminal bell'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
    });

    testWidgets('displays about section with version', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      // Scroll to find About section
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      expect(find.text('App version'), findsOneWidget);
      expect(find.text('0.1.0'), findsOneWidget);
      expect(find.text('GitHub'), findsOneWidget);
      expect(find.text('Licenses'), findsOneWidget);
    });

    testWidgets('displays security options', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Change PIN'), findsOneWidget);
      expect(find.text('Biometric authentication'), findsOneWidget);
      expect(find.text('Auto-lock timeout'), findsOneWidget);
    });

    testWidgets('has scrollable ListView', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            authServiceProvider.overrideWithValue(_FakeAuthService()),
            authStateProvider.overrideWith(_MockAuthStateNotifier.new),
          ],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.byType(ListView), findsOneWidget);
    });
  });
}

class _MockAuthStateNotifier extends AuthStateNotifier {
  @override
  AuthState build() => AuthState.notConfigured;

  @override
  AuthState get state => AuthState.notConfigured;
}

class _FakeAuthService extends AuthService {
  @override
  Future<bool> isAuthEnabled() async => false;

  @override
  Future<bool> isBiometricEnabled() async => false;

  @override
  Future<bool> isBiometricAvailable() async => false;
}
