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
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
    expect(previewText.style?.fontSize, 10.5);
    expect(previewText.style?.height, 1.22);
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

  test('stack preview metadata is separate from terminal preview text', () {
    final entry = buildConnectionPreviewStackEntry(
      connectionId: 1,
      state: SshConnectionState.connected,
      brightness: Brightness.dark,
      themeSettings: const TerminalThemeSettings(
        lightThemeId: TerminalThemes.defaultLightThemeId,
        darkThemeId: TerminalThemes.defaultDarkThemeId,
      ),
      availableThemes: TerminalThemes.all,
      preview: previewLines(15),
      workingDirectory: Uri.parse('file:///Users/depoll/Code/flutty'),
      shellStatus: TerminalShellStatus.runningCommand,
    );

    expect(entry.metadata, isNotNull);
    expect(entry.body.split('\n'), hasLength(15));
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

    expect(tester.getSize(find.byType(ConnectionPreviewStack)).height, 198);
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 15);
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
    expect(previewText.style?.fontSize, lessThanOrEqualTo(10.5));
    expect(previewText.style?.height, 1.22);
  });

  testWidgets('scales narrow stack previews instead of wrapping terminal rows', (
    tester,
  ) async {
    final preview = [
      'line 1',
      'this-is-a-long-terminal-row-that-should-scale-down-instead-of-wrapping',
      ...List.generate(13, (index) => 'line ${index + 3}'),
    ].join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: ConnectionPreviewStack(
              entries: [
                ConnectionPreviewStackEntry(
                  title: 'Connection #1',
                  body: preview,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
    expect(previewText.style?.fontSize, lessThan(10.5));
  });

  testWidgets('renders stack metadata without consuming preview line budget', (
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
                metadata: '~/Code/flutty • Running',
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(ConnectionPreviewStack)).height, 216);
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 15);
    expect(find.text('~/Code/flutty • Running'), findsOneWidget);
  });
}
