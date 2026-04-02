// ignore_for_file: public_member_api_docs

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
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
