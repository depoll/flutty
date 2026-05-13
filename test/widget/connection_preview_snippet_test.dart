// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/connection_preview_snippet.dart';

void main() {
  Widget buildSnippet({String? windowTitle, String? iconName}) => MaterialApp(
    home: Scaffold(
      body: ConnectionPreviewSnippet(
        endpoint: 'depoll@mac-mini.home:22 - Connection #1',
        preview: 'ready',
        windowTitle: windowTitle,
        iconName: iconName,
      ),
    ),
  );

  testWidgets(
    'shows one active title when the window title and icon name match',
    (tester) async {
      await tester.pumpWidget(
        buildSnippet(
          windowTitle: 'Designing app prompt',
          iconName: 'Designing app prompt',
        ),
      );

      expect(find.text('Active: Designing app prompt'), findsOneWidget);
      expect(find.text('Designing app prompt'), findsNothing);
    },
  );

  testWidgets('prefers the window title over the icon name', (tester) async {
    await tester.pumpWidget(
      buildSnippet(windowTitle: 'Designing app prompt', iconName: 'codex'),
    );

    expect(find.text('Active: Designing app prompt'), findsOneWidget);
    expect(find.text('Active: codex'), findsNothing);
  });

  test('stack preview titles do not duplicate matching metadata', () {
    final entry = buildConnectionPreviewStackEntry(
      connectionId: 1,
      state: SshConnectionState.connected,
      brightness: Brightness.dark,
      themeSettings: const TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      ),
      availableThemes: TerminalThemes.all,
      windowTitle: 'Designing app prompt',
      iconName: 'Designing app prompt',
    );

    expect(entry.title, startsWith('Connection #1'));
    expect(
      RegExp('Designing app prompt').allMatches(entry.title),
      hasLength(1),
    );
  });
}
