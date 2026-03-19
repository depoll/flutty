// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/data/database/database.dart';
import 'package:monkeyssh/presentation/screens/hosts_screen.dart';

void main() {
  group('normalizeSelectedGroupId', () {
    test('keeps the selected group when it still exists', () {
      final groups = [
        Group(
          id: 1,
          name: 'Production',
          sortOrder: 0,
          createdAt: DateTime(2026),
        ),
      ];

      final selectedGroupId = normalizeSelectedGroupId(
        selectedGroupId: 1,
        groups: groups,
      );

      expect(selectedGroupId, 1);
    });

    test('clears the selected group when imported data replaced group ids', () {
      final groups = [
        Group(
          id: 9,
          name: 'Production',
          sortOrder: 0,
          createdAt: DateTime(2026),
        ),
      ];

      final selectedGroupId = normalizeSelectedGroupId(
        selectedGroupId: 1,
        groups: groups,
      );

      expect(selectedGroupId, isNull);
    });
  });
}
