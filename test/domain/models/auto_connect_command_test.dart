// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/auto_connect_command.dart';

void main() {
  group('auto connect command helpers', () {
    test('resolves none mode when no command is configured', () {
      expect(
        resolveAutoConnectCommandMode(command: null, snippetId: null),
        AutoConnectCommandMode.none,
      );
    });

    test('prefers snippet mode when a snippet id is set', () {
      expect(
        resolveAutoConnectCommandMode(
          command: 'tmux new -As MonkeySSH',
          snippetId: 42,
        ),
        AutoConnectCommandMode.snippet,
      );
    });

    test('resolves custom mode when only a command is set', () {
      expect(
        resolveAutoConnectCommandMode(
          command: 'tmux new -As MonkeySSH',
          snippetId: null,
        ),
        AutoConnectCommandMode.custom,
      );
    });

    test('uses snippet command before falling back to stored command', () {
      expect(
        resolveAutoConnectCommandText(
          mode: AutoConnectCommandMode.snippet,
          storedCommand: 'cached command',
          snippetCommand: 'fresh snippet command',
        ),
        'fresh snippet command',
      );
      expect(
        resolveAutoConnectCommandText(
          mode: AutoConnectCommandMode.snippet,
          storedCommand: 'cached command',
        ),
        'cached command',
      );
    });

    test('adds a trailing enter for shell execution', () {
      expect(
        formatAutoConnectCommandForShell('tmux new -As MonkeySSH'),
        'tmux new -As MonkeySSH\r',
      );
      expect(formatAutoConnectCommandForShell('echo ready\r'), 'echo ready\r');
      expect(formatAutoConnectCommandForShell('echo ready\n'), 'echo ready\n');
    });
  });
}
