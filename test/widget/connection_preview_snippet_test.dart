// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/models/terminal_themes.dart';
import 'package:monkeyssh/domain/services/settings_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/widgets/connection_preview_snippet.dart';

void main() {
  Widget buildSnippet({
    String? preview = 'ready',
    String? sessionTitle,
    String? windowTitle,
    String? iconName,
  }) => MaterialApp(
    home: Scaffold(
      body: ConnectionPreviewSnippet(
        endpoint: 'depoll@mac-mini.home:22 - Connection #1',
        preview: preview,
        sessionTitle: sessionTitle,
        windowTitle: windowTitle,
        iconName: iconName,
      ),
    ),
  );
  String previewLines(int count) =>
      List.generate(count, (index) => 'line ${index + 1}').join('\n');

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

  testWidgets('prefers the session title over terminal metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildSnippet(
        sessionTitle: 'Implement onboarding',
        windowTitle: 'Designing app prompt',
        iconName: 'codex',
      ),
    );

    expect(find.text('Active: Implement onboarding'), findsOneWidget);
    expect(find.text('Active: Designing app prompt'), findsNothing);
  });

  testWidgets('renders about fifteen lines in the default preview', (
    tester,
  ) async {
    final preview = previewLines(17);

    await tester.pumpWidget(buildSnippet(preview: preview));

    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 15);
    expect(previewText.style?.fontSize, 8);
    expect(previewText.style?.height, 1.18);
  });

  test('stack preview titles prefer session title over terminal metadata', () {
    final entry = buildConnectionPreviewStackEntry(
      connectionId: 1,
      state: SshConnectionState.connected,
      brightness: Brightness.dark,
      themeSettings: const TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      ),
      availableThemes: TerminalThemes.all,
      sessionTitle: 'Implement onboarding',
      windowTitle: 'Designing app prompt',
      iconName: 'Designing app prompt',
    );

    expect(entry.title, startsWith('Connection #1'));
    expect(entry.title, contains('Implement onboarding'));
    expect(RegExp('Designing app prompt').allMatches(entry.title), isEmpty);
  });

  testWidgets('renders about fifteen lines in stacked previews', (
    tester,
  ) async {
    final preview = previewLines(17);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectionPreviewStack(
            entries: [
              ConnectionPreviewStackEntry(
                title: 'Connection #1',
                body: preview,
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(ConnectionPreviewStack)).height, 178);
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 15);
    expect(previewText.style?.fontSize, 8);
    expect(previewText.style?.height, 1.18);
  });
}
