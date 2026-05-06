import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_navigator.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('AgentToolIcon', () {
    testWidgets('renders a branded svg for a known tool name', (tester) async {
      await tester.pumpWidget(_wrap(const AgentToolIcon(toolName: 'Codex')));

      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    });

    testWidgets('renders a branded svg for a known tool enum', (tester) async {
      await tester.pumpWidget(
        _wrap(const AgentToolIcon(tool: AgentLaunchTool.copilotCli)),
      );

      expect(find.byType(SvgPicture), findsOneWidget);
      expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    });

    testWidgets('falls back to a Material icon for unknown tools', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const AgentToolIcon(
            toolName: 'Unknown CLI',
            fallbackIcon: Icons.terminal,
          ),
        ),
      );

      expect(find.byType(SvgPicture), findsNothing);
      expect(find.byIcon(Icons.terminal), findsOneWidget);
    });
  });

  group('TmuxToolPickerSheet', () {
    testWidgets('shows loading indicator while detection is pending', (
      tester,
    ) async {
      final completer = Completer<Set<AgentLaunchTool>>();
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            isProUser: true,
            installedToolsFuture: completer.future,
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );

      expect(find.text('Detecting installed CLIs…'), findsOneWidget);
      // No CLI tiles before detection completes.
      expect(find.text('Claude Code'), findsNothing);
      expect(find.text('Codex'), findsNothing);
      // Empty window remains available even while loading.
      expect(find.text('Empty window'), findsOneWidget);

      completer.complete({AgentLaunchTool.claudeCode});
      await tester.pump();
      expect(find.text('Detecting installed CLIs…'), findsNothing);
    });

    testWidgets('renders only detected tools', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            isProUser: true,
            installedToolsFuture: Future.value({
              AgentLaunchTool.claudeCode,
              AgentLaunchTool.codex,
            }),
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Claude Code'), findsOneWidget);
      expect(find.text('Codex'), findsOneWidget);
      // Tools that aren't installed must not appear.
      expect(find.text('Copilot CLI'), findsNothing);
      expect(find.text('Gemini CLI'), findsNothing);
      expect(find.text('OpenCode'), findsNothing);
      expect(find.text('Empty window'), findsOneWidget);
    });

    testWidgets('shows fallback message when no CLIs are detected', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            isProUser: true,
            installedToolsFuture: Future.value(const <AgentLaunchTool>{}),
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('No supported CLIs found on PATH.'), findsOneWidget);
      expect(find.text('Empty window'), findsOneWidget);
      for (final tool in AgentLaunchTool.values) {
        expect(find.text(tool.label), findsNothing);
      }
    });

    testWidgets(
      'falls back to all tools when no detection future is provided',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            TmuxToolPickerSheet(
              isProUser: true,
              onToolSelected: (_) {},
              onEmptyWindow: () {},
            ),
          ),
        );
        await tester.pump();

        for (final tool in AgentLaunchTool.values) {
          expect(find.text(tool.label), findsOneWidget);
        }
      },
    );

    testWidgets('shows fallback message when detection fails', (tester) async {
      final completer = Completer<Set<AgentLaunchTool>>();
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            isProUser: true,
            installedToolsFuture: completer.future,
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );
      completer.completeError(StateError('detection failed'));
      await tester.pump();

      expect(find.text('No supported CLIs found on PATH.'), findsOneWidget);
      expect(find.text('Empty window'), findsOneWidget);
      for (final tool in AgentLaunchTool.values) {
        expect(find.text(tool.label), findsNothing);
      }
    });

    testWidgets('invokes callback when a detected tool is tapped', (
      tester,
    ) async {
      AgentLaunchTool? chosen;
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            isProUser: true,
            installedToolsFuture: Future.value({AgentLaunchTool.claudeCode}),
            onToolSelected: (t) => chosen = t,
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Claude Code'));
      expect(chosen, AgentLaunchTool.claudeCode);
    });

    testWidgets('moves the preferred tool to the top of the list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          TmuxToolPickerSheet(
            isProUser: true,
            installedToolsFuture: Future.value({
              AgentLaunchTool.claudeCode,
              AgentLaunchTool.codex,
            }),
            preferredTool: AgentLaunchTool.codex,
            onToolSelected: (_) {},
            onEmptyWindow: () {},
          ),
        ),
      );
      await tester.pump();

      expect(
        tester.getTopLeft(find.text('Codex')).dy,
        lessThan(tester.getTopLeft(find.text('Claude Code')).dy),
      );
    });
  });
}
