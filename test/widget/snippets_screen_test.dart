// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/presentation/screens/snippet_edit_screen.dart';
import 'package:monkeyssh/presentation/screens/snippets_screen.dart';

class _MockSnippetRepository extends Mock implements SnippetRepository {}

Snippet _buildSnippet({
  required int id,
  required String name,
  required int sortOrder,
}) => Snippet(
  id: id,
  name: name,
  command: 'echo $name',
  autoExecute: false,
  createdAt: DateTime(2026),
  usageCount: 0,
  sortOrder: sortOrder,
);

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

  group('SnippetsScreen', () {
    testWidgets('shows imported snippets after the stream updates', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      final snippetsController = StreamController<List<Snippet>>();
      addTearDown(snippetsController.close);

      when(
        snippetRepository.watchAll,
      ).thenAnswer((_) => snippetsController.stream);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetsScreen()),
        ),
      );

      snippetsController.add(const <Snippet>[]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('No snippets yet'), findsOneWidget);

      snippetsController.add([
        _buildSnippet(id: 1, name: 'Imported snippet', sortOrder: 0),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Imported snippet'), findsOneWidget);
    });

    testWidgets('routes empty-state creation to the full snippet editor', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      when(
        snippetRepository.watchAll,
      ).thenAnswer((_) => Stream.value(const <Snippet>[]));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: MaterialApp.router(
            routerConfig: GoRouter(
              routes: [
                GoRoute(
                  path: '/',
                  builder: (context, state) => const SnippetsScreen(),
                ),
                GoRoute(
                  path: '/snippets/add',
                  builder: (context, state) =>
                      const Scaffold(body: Text('Full snippet editor')),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('No snippets yet'), findsOneWidget);
      expect(find.textContaining('tail -f {{log_file}}'), findsOneWidget);

      await tester.tap(find.text('Add Snippet').last);
      await tester.pumpAndSettle();

      expect(find.text('Full snippet editor'), findsOneWidget);
    });

    testWidgets('full editor updates variable preview as command changes', (
      tester,
    ) async {
      final snippetRepository = _MockSnippetRepository();
      when(
        snippetRepository.getAllFolders,
      ).thenAnswer((_) async => const <SnippetFolder>[]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetEditScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextFormField, 'Command'),
        'docker restart {{container}} && git checkout {{branch}}',
      );
      await tester.pump();

      expect(find.text('Variables'), findsOneWidget);
      expect(find.text('container'), findsOneWidget);
      expect(find.text('branch'), findsOneWidget);
    });

    testWidgets('reordering snippets persists the new order', (tester) async {
      final snippetRepository = _MockSnippetRepository();
      when(snippetRepository.watchAll).thenAnswer(
        (_) => Stream.value([
          _buildSnippet(id: 1, name: 'First', sortOrder: 0),
          _buildSnippet(id: 2, name: 'Second', sortOrder: 1),
        ]),
      );
      when(
        () => snippetRepository.reorderByIds(any()),
      ).thenAnswer((_) async {});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            snippetRepositoryProvider.overrideWithValue(snippetRepository),
          ],
          child: const MaterialApp(home: SnippetsScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Reorder'), findsNWidgets(2));

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorder(0, 2);
      await tester.pumpAndSettle();

      verify(() => snippetRepository.reorderByIds([2, 1])).called(1);
    });
  });
}
