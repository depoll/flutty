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

  testWidgets('renders extra rows in the default preview', (tester) async {
    final preview = previewLines(19);

    await tester.pumpWidget(buildSnippet(preview: preview));

    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 17);
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
      preview: previewLines(17),
      workingDirectory: Uri.parse('file:///Users/depoll/Code/flutty'),
      shellStatus: TerminalShellStatus.runningCommand,
    );

    expect(entry.metadata, isNotNull);
    expect(entry.body.split('\n'), hasLength(17));
  });

  testWidgets('renders extra rows in stacked previews', (tester) async {
    final preview = previewLines(19);

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
    expect(previewText.maxLines, 17);
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
    expect(previewText.style?.fontSize, lessThanOrEqualTo(10.5));
    expect(previewText.style?.height, 1.22);
  });

  testWidgets('clips narrow stack previews instead of wrapping terminal rows', (
    tester,
  ) async {
    final preview = [
      'line 1',
      'this-is-a-long-terminal-row-that-should-scale-down-instead-of-wrapping',
      ...List.generate(15, (index) => 'line ${index + 3}'),
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
    expect(tester.getSize(find.byType(ConnectionPreviewStack)).height, 198);
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
  });

  testWidgets('sizes stack previews to rendered rows', (tester) async {
    final preview = previewLines(6);

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

    expect(
      tester.getSize(find.byType(ConnectionPreviewStack)).height,
      lessThan(198),
    );
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.maxLines, 17);
  });

  testWidgets('sizes long non-wrapping previews to terminal rows', (
    tester,
  ) async {
    final preview = [
      'cd',
      '/Users/depoll/Code/flutty.worktrees/connection-preview-10-lines',
      'git --no-pager diff --check',
      'git add lib/presentation/widgets/connection_preview_snippet.dart',
      '74 lines...',
      'Pushed a guard to PR #500:',
      'https://github.com/depollsoft/MonkeySSH/pull/500',
      'Repeated taps on an active connection now go through a single',
      'debounced terminal-route opener, so they cannot stack duplicate',
      'instances of the same terminal page.',
      'Added a regression test that double-taps a connection and verifies',
      'only one terminal route is pushed.',
      '~/Code/flutty [main*%]',
      '────────────────────────────────────────────────────────',
      '›',
      '────────────────────────────────────────────────────────',
      '/ commands · ? helpGPT-5.5 · xhigh (25%)',
    ].join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 710,
            child: ConnectionPreviewStack(
              entries: [
                ConnectionPreviewStackEntry(
                  title: 'Connection #1 • Adjust Connection Preview Length',
                  body: preview,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final stackHeight = tester
        .getSize(find.byType(ConnectionPreviewStack))
        .height;
    expect(stackHeight, 198);
    final previewText = tester.widget<Text>(find.text(preview));
    expect(previewText.softWrap, isFalse);
    expect(previewText.overflow, TextOverflow.clip);
  });

  testWidgets('renders stack metadata without consuming preview line budget', (
    tester,
  ) async {
    final preview = previewLines(19);

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
    expect(previewText.maxLines, 17);
    expect(find.text('~/Code/flutty • Running'), findsOneWidget);
  });
}
