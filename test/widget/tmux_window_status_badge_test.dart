import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/widgets/tmux_window_status_badge.dart';

void main() {
  group('TmuxWindowStatusBadge', () {
    testWidgets('shows waiting for the active idle window', (tester) async {
      const window = TmuxWindow(
        index: 0,
        name: 'claude',
        isActive: true,
        currentCommand: 'claude',
        idleSeconds: 120,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      expect(find.text('waiting'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_bottom), findsOneWidget);
    });

    testWidgets('shows running for the active window by default', (
      tester,
    ) async {
      const window = TmuxWindow(index: 0, name: 'vim', isActive: true);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      expect(find.text('running'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('uses high-contrast container colors for alert badges', (
      tester,
    ) async {
      const scheme = ColorScheme.light(
        errorContainer: Color(0xFF112233),
        onErrorContainer: Color(0xFFF1E2D3),
      );
      const window = TmuxWindow(
        index: 2,
        name: 'logs',
        isActive: false,
        flags: '#!',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: scheme),
          home: const Scaffold(
            body: Center(child: TmuxWindowStatusBadge(window: window)),
          ),
        ),
      );

      final badge = tester.widget<DecoratedBox>(
        find.byType(DecoratedBox).first,
      );
      final decoration = badge.decoration as BoxDecoration;
      final icon = tester.widget<Icon>(find.byIcon(Icons.notifications_active));
      final text = tester.widget<Text>(find.text('alert'));

      expect(decoration.color, scheme.errorContainer);
      expect(icon.color, scheme.onErrorContainer);
      expect(text.style?.color, scheme.onErrorContainer);
    });
  });
}
