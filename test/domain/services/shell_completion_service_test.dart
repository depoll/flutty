import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/shell_completion_service.dart';

void main() {
  group('buildShellCompletionInvocation', () {
    test('uses a captured prompt prefix to isolate the command text', () {
      const prompt = 'depoll@mac-mini ~ % ';
      final invocation = buildShellCompletionInvocation(
        terminalText: '${prompt}c',
        terminalCursorOffset: '${prompt}c'.length,
        promptPrefix: prompt,
        workingDirectory: '/Users/depoll',
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'c');
      expect(invocation.cursorOffset, 1);
      expect(invocation.token, 'c');
      expect(invocation.tokenStart, 0);
      expect(invocation.mode, ShellCompletionMode.command);
      expect(invocation.workingDirectory, '/Users/depoll');
    });

    test('falls back to common shell prompt markers', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: r'tester@host ~/project $ git',
        terminalCursorOffset: r'tester@host ~/project $ git'.length,
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'git');
      expect(invocation.mode, ShellCompletionMode.command);
    });

    test('resolves cd arguments as directory completions', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % cd Ser',
        terminalCursorOffset: 'tester@host ~ % cd Ser'.length,
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'cd Ser');
      expect(invocation.commandName, 'cd');
      expect(invocation.token, 'Ser');
      expect(invocation.tokenStart, 3);
      expect(invocation.mode, ShellCompletionMode.directory);
    });

    test('does not request all commands at an empty prompt', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % ',
        terminalCursorOffset: 'tester@host ~ % '.length,
      );

      expect(invocation, isNull);
    });

    test('does not request all paths after an empty argument token', () {
      final pathInvocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % git ',
        terminalCursorOffset: 'tester@host ~ % git '.length,
      );
      final directoryInvocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % cd ',
        terminalCursorOffset: 'tester@host ~ % cd '.length,
      );

      expect(pathInvocation, isNull);
      expect(directoryInvocation, isNull);
    });
  });

  group('parseShellCompletionOutput', () {
    test('builds command and cd shortcut suggestions', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'c',
        cursorOffset: 1,
        token: 'c',
        tokenStart: 0,
        mode: ShellCompletionMode.command,
        workingDirectory: '/Users/depoll',
      );

      final suggestions = parseShellCompletionOutput(
        [
          'command\tcat',
          'command\tcd',
          'cd_directory\tServices',
          'cd_directory\t..',
        ].join('\n'),
        invocation,
      );

      expect(suggestions.map((suggestion) => suggestion.label), [
        'cd',
        'cd ..',
        'cd Services/',
        'cat',
      ]);
      expect(suggestions.first.replacement, 'cd');
      expect(suggestions.first.commitSuffix, ' ');
      expect(suggestions[2].replacement, 'cd Services/');
      expect(suggestions[2].replacementStart, 0);
    });

    test('escapes spaces in path replacements', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'cd Pro',
        cursorOffset: 6,
        token: 'Pro',
        tokenStart: 3,
        mode: ShellCompletionMode.directory,
        commandName: 'cd',
        workingDirectory: '/Users/depoll',
      );

      final suggestions = parseShellCompletionOutput(
        'directory\tProject Files',
        invocation,
      );

      expect(suggestions.single.label, 'cd Project Files/');
      expect(suggestions.single.replacement, r'Project\ Files/');
      expect(suggestions.single.replacementStart, 3);
      expect(suggestions.single.replacementEnd, 6);
    });
  });

  test('escapeShellCompletionToken escapes shell metacharacters', () {
    expect(
      escapeShellCompletionToken('Project Files/(draft)'),
      r'Project\ Files/\(draft\)',
    );
  });

  test('remote command sources startup files through the user shell', () {
    const invocation = ShellCompletionInvocation(
      commandLine: 'gi',
      cursorOffset: 2,
      token: 'gi',
      tokenStart: 0,
      mode: ShellCompletionMode.command,
      workingDirectory: '/Users/depoll/project',
    );

    final command = buildShellCompletionRemoteCommand(invocation);

    expect(command, contains(r'flutty_shell=${SHELL:-}'));
    expect(
      command,
      contains(
        "export FLUTTY_MODE='command' FLUTTY_TOKEN='gi' FLUTTY_INCLUDE_CD_SHORTCUTS=0 FLUTTY_CWD='/Users/depoll/project' FLUTTY_LIMIT=96;",
      ),
    );
    expect(command, contains(r'FLUTTY_PROFILE_KIND=$flutty_profile_kind'));
    expect(command, contains(r'source_if_readable "$HOME/.zprofile"'));
    expect(command, contains(r'source_if_readable "$HOME/.zshrc"'));
    expect(command, contains(r'''printf '%s\n' "$item"'''));
    expect(command, contains(r'source_if_readable "$HOME/.bash_profile"'));
    expect(command, contains(r'emit_line command "$item" || break'));
    expect(command, contains("FLUTTY_CWD='/Users/depoll/project'"));
  });
}
