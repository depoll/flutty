// ignore_for_file: public_member_api_docs

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:flutty/data/database/database.dart';
import 'package:flutty/presentation/screens/home_screen.dart';

void main() {
  Widget buildTestWidget(AppDatabase db, {Size size = const Size(800, 600)}) {
    return ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db)],
      child: MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const HomeScreen(),
              ),
              GoRoute(
                path: '/settings',
                builder: (context, state) => const Scaffold(),
              ),
              GoRoute(
                path: '/hosts/add',
                builder: (context, state) => const Scaffold(),
              ),
              GoRoute(
                path: '/hosts/:id/edit',
                builder: (context, state) => const Scaffold(),
              ),
              GoRoute(
                path: '/terminal/:hostId',
                builder: (context, state) => const Scaffold(),
              ),
              GoRoute(
                path: '/keys/add',
                builder: (context, state) => const Scaffold(),
              ),
              GoRoute(
                path: '/snippets',
                builder: (context, state) => const Scaffold(),
              ),
              GoRoute(
                path: '/port-forwards',
                builder: (context, state) => const Scaffold(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  group('HomeScreen Desktop Layout', () {
    testWidgets('displays app title in sidebar', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db));
      await tester.pumpAndSettle();

      expect(find.text('Flutty'), findsOneWidget);
    });

    testWidgets('displays navigation items in sidebar', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db));
      await tester.pumpAndSettle();

      expect(find.text('Hosts'), findsOneWidget);
      expect(find.text('Keys'), findsOneWidget);
      expect(find.text('Snippets'), findsOneWidget);
      expect(find.text('Port Forwarding'), findsOneWidget);
      expect(find.text('Settings'), findsOneWidget);
    });

    testWidgets('displays settings icon', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    });

    testWidgets('displays hosts panel by default', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db));
      await tester.pumpAndSettle();

      // Hosts panel should have "Hosts" header and Add Host button
      expect(find.text('Add Host'), findsOneWidget);
    });

    testWidgets('displays sidebar navigation icons', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.dns_rounded), findsOneWidget);
      expect(find.byIcon(Icons.key_rounded), findsOneWidget);
      expect(find.byIcon(Icons.code_rounded), findsOneWidget);
      expect(find.byIcon(Icons.swap_horiz_rounded), findsOneWidget);
    });

    testWidgets('switches to keys panel when Keys is tapped', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keys'));
      await tester.pumpAndSettle();

      expect(find.text('SSH Keys'), findsOneWidget);
      expect(find.text('Add Key'), findsOneWidget);
    });
  });

  group('HomeScreen Mobile Layout', () {
    testWidgets('displays bottom navigation bar on narrow screens', (
      tester,
    ) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db, size: const Size(400, 800)));
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
    });

    testWidgets('displays app bar on narrow screens', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db, size: const Size(400, 800)));
      await tester.pumpAndSettle();

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('Flutty'), findsOneWidget);
    });

    testWidgets('displays settings icon in app bar on mobile', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db, size: const Size(400, 800)));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    });

    testWidgets('bottom nav has correct destinations', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db, size: const Size(400, 800)));
      await tester.pumpAndSettle();

      expect(find.text('Hosts'), findsOneWidget);
      expect(find.text('Keys'), findsOneWidget);
      expect(find.text('Snippets'), findsOneWidget);
      expect(find.text('Ports'), findsOneWidget);
    });
  });

  group('HomeScreen Empty States', () {
    testWidgets('shows empty state when no hosts', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db));
      await tester.pumpAndSettle();

      expect(find.text('No hosts yet'), findsOneWidget);
    });

    testWidgets('shows empty state when no keys', (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);

      await tester.pumpWidget(buildTestWidget(db));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Keys'));
      await tester.pumpAndSettle();

      expect(find.text('No SSH keys yet'), findsOneWidget);
    });
  });
}
