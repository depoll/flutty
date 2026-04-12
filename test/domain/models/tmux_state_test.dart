// ignore_for_file: public_member_api_docs

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/tmux_state.dart';

void main() {
  group('TmuxSession', () {
    test('parses from tmux format string', () {
      const line = 'dev\t3\t1\t1712930000';
      final session = TmuxSession.fromTmuxFormat(line);

      expect(session.name, 'dev');
      expect(session.windowCount, 3);
      expect(session.isAttached, true);
      expect(session.lastActivity, isNotNull);
    });

    test('parses unattached session', () {
      const line = 'build\t1\t0\t1712920000';
      final session = TmuxSession.fromTmuxFormat(line);

      expect(session.name, 'build');
      expect(session.windowCount, 1);
      expect(session.isAttached, false);
    });

    test('handles missing activity field', () {
      const line = 'test\t2\t0';
      final session = TmuxSession.fromTmuxFormat(line);

      expect(session.name, 'test');
      expect(session.windowCount, 2);
      expect(session.lastActivity, isNull);
    });

    test('throws on too few fields', () {
      expect(() => TmuxSession.fromTmuxFormat('bad\t1'), throwsFormatException);
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
      const line = '0\tvim\t1\tvim\t/home/user/project';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.index, 0);
      expect(window.name, 'vim');
      expect(window.isActive, true);
      expect(window.currentCommand, 'vim');
      expect(window.currentPath, '/home/user/project');
    });

    test('parses with minimal fields', () {
      const line = '2\tbash\t0';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.index, 2);
      expect(window.name, 'bash');
      expect(window.isActive, false);
      expect(window.currentCommand, isNull);
      expect(window.currentPath, isNull);
    });

    test('handles empty command and path', () {
      const line = '1\tshell\t0\t\t';
      final window = TmuxWindow.fromTmuxFormat(line);

      expect(window.currentCommand, isNull);
      expect(window.currentPath, isNull);
    });

    test('throws on too few fields', () {
      expect(() => TmuxWindow.fromTmuxFormat('0\tvim'), throwsFormatException);
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

      expect(active.statusLabel, 'active');
      expect(running.statusLabel, 'running');
      expect(idle.statusLabel, 'idle');
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
}
