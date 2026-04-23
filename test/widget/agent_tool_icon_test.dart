import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:monkeyssh/domain/models/agent_launch_preset.dart';
import 'package:monkeyssh/presentation/widgets/agent_tool_icon.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('renders a branded svg for a known tool name', (tester) async {
    await tester.pumpWidget(wrap(const AgentToolIcon(toolName: 'Codex')));

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
  });

  testWidgets('renders a branded svg for a known tool enum', (tester) async {
    await tester.pumpWidget(
      wrap(const AgentToolIcon(tool: AgentLaunchTool.copilotCli)),
    );

    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
  });

  testWidgets('falls back to a Material icon for unknown tools', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AgentToolIcon(
          toolName: 'Unknown CLI',
          fallbackIcon: Icons.terminal,
        ),
      ),
    );

    expect(find.byType(SvgPicture), findsNothing);
    expect(find.byIcon(Icons.terminal), findsOneWidget);
  });
}
