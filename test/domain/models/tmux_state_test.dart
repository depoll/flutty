// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';

void main() {
  group('TmuxSession', () {
    test('parses from tmux format string', () {
      const line = 'dev|3|1|1712930000';
      final session = TmuxSession.fromTmuxFormat(line);

      expect(session.name, 'dev');
      expect(session.windowCount, 3);
      expect(session.isAttached, true);
      expect(session.lastActivity, isNotNull);
    });

    test('parses unattached session', () {
      const line = 'build|1|0|1712920000';
      final session = TmuxSession.fromTmuxFormat(line);

      expect(session.name, 'build');
      expect(session.windowCount, 1);
      expect(session.isAttached, false);
    });

    test('handles missing activity field', () {
      const line = 'test|2|0';
      final session = TmuxSession.fromTmuxFormat(line);

      expect(session.name, 'test');
      expect(session.windowCount, 2);
      expect(session.lastActivity, isNull);
    });

    test('throws on too few fields', () {
      expect(() => TmuxSession.fromTmuxFormat('bad|1'), throwsFormatException);
    });

    test('equality works correctly', () {
      const a = TmuxSession(name: 'dev', windowCount: 3, isAttached: true);
      const b = TmuxSession(name: 'dev', windowCount: 3, isAttached: true);
      const c = TmuxSession(name: 'prod', windowCount: 1, isAttached: false);

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, b.hashCode);
    });
  });

  group('TmuxWindow', () {
    test('parses from tmux format string with all fields', () {
      const line = '0|vim|1|vim|/home/user/project|*|Editing main.dart';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.index, 0);
      expect(window.name, 'vim');
      expect(window.isActive, true);
      expect(window.currentCommand, 'vim');
      expect(window.currentPath, '/home/user/project');
      expect(window.flags, '*');
      expect(window.paneTitle, 'Editing main.dart');
      expect(window.displayTitle, 'Editing main.dart');
      expect(window.hasAlert, false);
    });

    test('parses with minimal fields', () {
      const line = '2|bash|0';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.index, 2);
      expect(window.name, 'bash');
      expect(window.isActive, false);
      expect(window.currentCommand, isNull);
      expect(window.currentPath, isNull);
      expect(window.flags, isNull);
      expect(window.paneTitle, isNull);
      expect(window.displayTitle, 'bash');
    });

    test('strips placeholder underscores from emoji-mangled window names', () {
      const window = TmuxWindow(
        index: 1,
        name: '__ test-emoji',
        isActive: false,
      );

      expect(window.displayTitle, 'test-emoji');
      expect(window.secondaryTitle, isNull);
    });

    test('exposes secondaryTitle when pane title differs from window name', () {
      const window = TmuxWindow(
        index: 1,
        name: 'claude',
        isActive: false,
        paneTitle: '✨ Editing main.dart',
      );

      expect(window.displayTitle, '✨ Editing main.dart');
      expect(window.secondaryTitle, 'claude');
    });

    test('handles empty command and path', () {
      const line = '1|shell|0||';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.currentCommand, isNull);
      expect(window.currentPath, isNull);
    });

    test('detects alert flag', () {
      const line = '3|build|0|make|/tmp|#|Building project';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.hasAlert, true);
      expect(window.statusLabel, 'alert');
    });

    test('throws on too few fields', () {
      expect(() => TmuxWindow.fromTmuxFormat('0|vim'), throwsFormatException);
    });

    test('statusLabel returns correct values', () {
      const active = TmuxWindow(index: 0, name: 'vim', isActive: true);
      const running = TmuxWindow(
        index: 1,
        name: 'build',
        isActive: false,
        currentCommand: 'make',
      );
      const idle = TmuxWindow(index: 2, name: 'bash', isActive: false);
      const waiting = TmuxWindow(
        index: 3,
        name: 'claude',
        isActive: false,
        currentCommand: 'claude',
        idleSeconds: 120,
      );

      expect(active.statusLabel, '');
      expect(running.statusLabel, '');
      expect(idle.statusLabel, '');
      expect(waiting.statusLabel, 'waiting');
      expect(waiting.isIdle, true);
    });

    test('equality works correctly', () {
      const a = TmuxWindow(index: 0, name: 'vim', isActive: true);
      const b = TmuxWindow(index: 0, name: 'vim', isActive: true);
      const c = TmuxWindow(index: 1, name: 'bash', isActive: false);

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('ToolSessionInfo', () {
    test('constructs with all fields', () {
      final info = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: 'abc123',
        workingDirectory: '/home/user/project',
        lastActive: DateTime(2026, 4, 12),
        summary: 'Fix auth middleware',
      );

      expect(info.toolName, 'Claude Code');
      expect(info.sessionId, 'abc123');
      expect(info.summary, 'Fix auth middleware');
    });

    test('timeAgoLabel formats correctly', () {
      final now = DateTime.now();

      final justNow = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '1',
        lastActive: now,
      );
      expect(justNow.timeAgoLabel, 'just now');

      final minutesAgo = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '2',
        lastActive: now.subtract(const Duration(minutes: 30)),
      );
      expect(minutesAgo.timeAgoLabel, '30m ago');

      final hoursAgo = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '3',
        lastActive: now.subtract(const Duration(hours: 5)),
      );
      expect(hoursAgo.timeAgoLabel, '5h ago');

      final daysAgo = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '4',
        lastActive: now.subtract(const Duration(days: 3)),
      );
      expect(daysAgo.timeAgoLabel, '3d ago');

      final weeksAgo = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '5',
        lastActive: now.subtract(const Duration(days: 14)),
      );
      expect(weeksAgo.timeAgoLabel, '2w ago');
    });

    test('timeAgoLabel returns empty when lastActive is null', () {
      const info = ToolSessionInfo(toolName: 'Codex', sessionId: '1');
      expect(info.timeAgoLabel, '');
    });

    test('lastUpdatedLabel includes date and relative time', () {
      final now = DateTime.now();
      final lastActive = now.subtract(const Duration(hours: 5));
      final info = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: '6',
        lastActive: lastActive,
      );

      final month = const [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ][lastActive.month - 1];
      expect(info.lastUpdatedLabel, '$month ${lastActive.day} | 5h ago');
    });

    test('equality uses toolName and sessionId', () {
      const a = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: 'abc',
        summary: 'session A',
      );
      const b = ToolSessionInfo(
        toolName: 'Claude Code',
        sessionId: 'abc',
        summary: 'different summary',
      );
      const c = ToolSessionInfo(toolName: 'Codex', sessionId: 'abc');

      expect(a, equals(b));
      expect(a, isNot(equals(c)));
    });
  });

  group('parseTmuxSessionName', () {
    test('parses -s flag from new-session', () {
      expect(
        parseTmuxSessionName('tmux new-session -A -s myproject'),
        'myproject',
      );
    });

    test('parses combined -As flag', () {
      expect(parseTmuxSessionName('tmux new -As MonkeySSH'), 'MonkeySSH');
    });

    test('parses -t flag from attach', () {
      expect(parseTmuxSessionName('tmux attach -t dev'), 'dev');
    });

    test('parses quoted session name', () {
      expect(
        parseTmuxSessionName("tmux new-session -A -s 'my project'"),
        'my project',
      );
    });

    test('parses with cd prefix', () {
      expect(
        parseTmuxSessionName('cd /home/user && tmux new -As work'),
        'work',
      );
    });

    test('returns null for non-tmux command', () {
      expect(parseTmuxSessionName('htop'), isNull);
    });

    test('returns null for tmux subcommands containing flag-like suffixes', () {
      expect(parseTmuxSessionName('tmux list-sessions'), isNull);
      expect(
        parseTmuxSessionName('tmux list-sessions -F #{session_name}'),
        isNull,
      );
    });

    test('returns null for null/empty', () {
      expect(parseTmuxSessionName(null), isNull);
      expect(parseTmuxSessionName(''), isNull);
    });
  });

  group('buildTmuxCommand', () {
    test('builds basic command', () {
      expect(
        buildTmuxCommand(sessionName: 'dev'),
        "tmux new-session -A -s 'dev'",
      );
    });

    test('includes working directory', () {
      expect(
        buildTmuxCommand(sessionName: 'dev', workingDirectory: '/home/user'),
        "tmux new-session -A -s 'dev' -c '/home/user'",
      );
    });

    test('includes extra flags', () {
      expect(
        buildTmuxCommand(sessionName: 'dev', extraFlags: '-x 200 -y 50'),
        "tmux new-session -A -s 'dev' -x 200 -y 50",
      );
    });

    test('includes all options', () {
      expect(
        buildTmuxCommand(
          sessionName: 'dev',
          workingDirectory: '/tmp',
          extraFlags: '-n editor',
        ),
        "tmux new-session -A -s 'dev' -c '/tmp' -n editor",
      );
    });
  });
}
