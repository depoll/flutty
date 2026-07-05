import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/agent_session_discovery_service.dart';
import 'package:monkeyssh/domain/services/shell_completion_service.dart';
import 'package:monkeyssh/domain/services/windows_remote_powershell.dart';

/// Decodes a UTF-16LE `-EncodedCommand` payload back to its script text.
String _decodeUtf16le(String base64Text) {
  final bytes = base64.decode(base64Text);
  final buffer = StringBuffer();
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    buffer.writeCharCode(bytes[i] | (bytes[i + 1] << 8));
  }
  return buffer.toString();
}

void main() {
  group('encodePowerShellCommand', () {
    test('round-trips through UTF-16LE base64', () {
      const script = 'Write-Output "café — 1 + 2 = 3"';
      expect(_decodeUtf16le(encodePowerShellCommand(script)), script);
    });

    test(
      'buildWindowsPowerShellCommand wraps an EncodedCommand invocation',
      () {
        const script = "Get-ChildItem 'x'";
        final command = buildWindowsPowerShellCommand(script);
        expect(command, startsWith('powershell -NoProfile -NonInteractive '));
        expect(command, contains('-EncodedCommand '));
        final encoded = command.split('-EncodedCommand ').last;
        expect(_decodeUtf16le(encoded), script);
      },
    );
  });

  group('powerShellSingleQuote', () {
    test('wraps in single quotes and doubles embedded quotes', () {
      expect(powerShellSingleQuote('plain'), "'plain'");
      expect(powerShellSingleQuote("it's"), "'it''s'");
    });
  });

  group('windowsListNewestFilesScript', () {
    test('filters by name via Where-Object, not -Include (5.1 safe)', () {
      final script = windowsListNewestFilesScript(
        relativeRoot: '.codex/sessions',
        includeGlobs: const ['rollout-*.jsonl'],
        limit: 120,
      );
      // -Include is silently ignored with -LiteralPath on Windows PowerShell
      // 5.1, so it must never be used for name filtering.
      expect(script, isNot(contains('-Include ')));
      expect(script, contains('Get-ChildItem -LiteralPath'));
      expect(script, contains(r"$__flN -like 'rollout-*.jsonl'"));
      expect(script, contains('Sort-Object LastWriteTimeUtc -Descending'));
      expect(script, contains('Select-Object -First 120'));
      expect(script, contains("'.codex/sessions'"));
      // Emits forward-slash paths.
      expect(script, contains(r"-replace '\\','/'"));
    });

    test('includes path-like filters when provided', () {
      final script = windowsListNewestFilesScript(
        relativeRoot: '.gemini/tmp',
        includeGlobs: const ['session-*.json', 'session-*.jsonl'],
        limit: 40,
        pathLikeFilters: const ['*/chats/*'],
      );
      expect(script, contains(r"$__flN -like 'session-*.json'"));
      expect(script, contains(r"$__flN -like 'session-*.jsonl'"));
      expect(script, contains(r"$__flFn -like '*/chats/*'"));
    });
  });

  group('windowsFindFilesByNameScript', () {
    test('matches each exact name via Where-Object', () {
      final script = windowsFindFilesByNameScript(
        relativeRoot: '.claude/projects',
        names: const ['abc-123.jsonl', 'def-456.jsonl'],
      );
      expect(script, isNot(contains('-Include ')));
      expect(script, contains(r"$__flN -like 'abc-123.jsonl'"));
      expect(script, contains(r"$__flN -like 'def-456.jsonl'"));
    });
  });

  group('windowsTailFileScript', () {
    test('reads the last N lines of a USERPROFILE-relative file', () {
      final script = windowsTailFileScript(
        relativePath: '.claude/history.jsonl',
        lines: 200,
      );
      expect(script, contains(r'Join-Path $env:USERPROFILE'));
      expect(script, contains("'.claude/history.jsonl'"));
      expect(script, contains(r'Get-Content -LiteralPath $__flPath -Tail 200'));
    });
  });

  group('windowsFileSnapshotScript', () {
    test('emits the SEP-delimited snapshot format', () {
      final script = windowsFileSnapshotScript(const ['C:/x/y.jsonl']);
      expect(script, contains(r'$SEP=[char]0x1f'));
      expect(script, contains("'C:/x/y.jsonl'"));
      expect(script, contains('ReadAllBytes'));
      expect(script, contains('ToBase64String'));
    });

    test('reads the first N bytes for maxBytes', () {
      final script = windowsFileSnapshotScript(const [
        'C:/x/y.json',
      ], maxBytes: 65536);
      expect(script, contains('New-Object byte[] 65536'));
      expect(script, contains(r'$fs.Read($buf,0,$buf.Length)'));
    });

    test('reads head or tail lines for maxLines', () {
      final head = windowsFileSnapshotScript(const [
        'C:/x/y.jsonl',
      ], maxLines: 80);
      expect(head, contains('-TotalCount 80'));
      final tail = windowsFileSnapshotScript(
        const ['C:/x/y.jsonl'],
        maxLines: 80,
        tail: true,
      );
      expect(tail, contains('-Tail 80'));
    });
  });

  group('buildWindowsShellCompletionScript', () {
    test('command mode queries Get-Command with the token', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'gi',
        cursorOffset: 2,
        token: 'gi',
        tokenStart: 0,
        mode: ShellCompletionMode.command,
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellCompletionScript(invocation);
      expect(script, contains(r"$__flMode='command'"));
      expect(script, contains(r"$__flToken='gi'"));
      expect(script, contains('Get-Command -Name'));
      expect(script, contains("Append('command')"));
    });

    test('path mode enumerates directories and files', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'type .cop',
        cursorOffset: 9,
        token: '.cop',
        tokenStart: 5,
        mode: ShellCompletionMode.path,
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellCompletionScript(invocation);
      expect(script, contains(r"$__flMode='path'"));
      expect(script, contains('Get-ChildItem -LiteralPath'));
      expect(script, contains("Append('directory')"));
      expect(script, contains("Append('file')"));
    });
  });

  group('buildWindowsShellHistoryScript', () {
    test('reads PSReadLine history and emits bash-sourced lines', () {
      const invocation = ShellCompletionInvocation(
        commandLine: '',
        cursorOffset: 0,
        token: '',
        tokenStart: 0,
        mode: ShellCompletionMode.command,
        workingDirectory: r'C:\Users\x',
      );
      final script = buildWindowsShellHistoryScript(invocation);
      expect(script, contains('ConsoleHost_history.txt'));
      expect(script, contains("Append('__FLUTTY_HISTORY_START__')"));
      expect(script, contains("Append('__FLUTTY_HISTORY_DONE__')"));
      expect(script, contains("Append('bash')"));
      expect(
        script,
        contains(r'Get-Content -LiteralPath $__flHist -Tail 1200'),
      );
    });
  });
}
