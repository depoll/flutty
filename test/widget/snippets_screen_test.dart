// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/data/repositories/snippet_repository.dart';
import 'package:monkeyssh/presentation/screens/snippets_screen.dart';

class _MockSnippetRepository extends Mock implements SnippetRepository {}

void main() {
  setUpAll(() {
    registerFallbackValue(<int>[]);
  });

  group('SnippetsScreen', () {
    testWidgets('shows loading indicator initially', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: SnippetsScreen())),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('reordering snippets persists the new order', (tester) async {
      final snippetRepository = _MockSnippetRepository();
      when(snippetRepository.getAll).thenAnswer(
        (_) async => [
          Snippet(
            id: 1,
            name: 'First',
            command: 'echo first',
            autoExecute: false,
            createdAt: DateTime(2026),
            usageCount: 0,
            sortOrder: 0,
          ),
          Snippet(
            id: 2,
            name: 'Second',
            command: 'echo second',
            autoExecute: false,
            createdAt: DateTime(2026),
            usageCount: 0,
            sortOrder: 1,
          ),
        ],
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
