import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';

void main() {
  group('resolveTmuxAlertNotificationContent', () {
    test('uses the session name as title and window title as body', () {
      const window = TmuxWindow(
        index: 2,
        name: 'agent',
        isActive: false,
        paneTitle: 'Build finished',
      );

      final content = resolveTmuxAlertNotificationContent(
        tmuxSessionName: ' work ',
        window: window,
        windows: const <TmuxWindow>[
          TmuxWindow(index: 0, name: 'shell', isActive: true),
          window,
        ],
      );

      expect(content.title, 'tmux alert · work');
      expect(content.body, 'Build finished');
    });

    test('adds the window number when the title is ambiguous', () {
      const window = TmuxWindow(
        index: 2,
        name: 'agent-a',
        isActive: false,
        paneTitle: 'Build   finished',
      );

      final content = resolveTmuxAlertNotificationContent(
        tmuxSessionName: 'work',
        window: window,
        windows: const <TmuxWindow>[
          window,
          TmuxWindow(
            index: 3,
            name: 'agent-b',
            isActive: false,
            paneTitle: 'Build finished',
          ),
        ],
      );

      expect(content.title, 'tmux alert · work');
      expect(content.body, 'Build finished (window #2)');
    });

    test('falls back to the window number without a usable title', () {
      const window = TmuxWindow(index: 4, name: '   ', isActive: false);

      final content = resolveTmuxAlertNotificationContent(
        tmuxSessionName: '',
        window: window,
        windows: const <TmuxWindow>[window],
      );

      expect(content.title, 'tmux alert');
      expect(content.body, 'Window #4 needs attention');
    });
  });
}
