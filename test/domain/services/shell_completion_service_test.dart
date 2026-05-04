import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/shell_completion_service.dart';

void main() {
  group('buildShellCompletionInvocation', () {
    test('uses a captured prompt prefix to isolate the command text', () {
      const prompt = 'depoll@mac-mini ~ % ';
      final invocation = buildShellCompletionInvocation(
        terminalText: '${prompt}gi',
        terminalCursorOffset: '${prompt}gi'.length,
        promptPrefix: prompt,
        workingDirectory: '/Users/depoll',
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'gi');
      expect(invocation.cursorOffset, 2);
      expect(invocation.token, 'gi');
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

    test('does not request dynamic argument completions for empty tokens', () {
      final argumentInvocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % git ',
        terminalCursorOffset: 'tester@host ~ % git '.length,
      );

      expect(argumentInvocation, isNull);
    });

    test('requests shell-native argument completions for typed tokens', () {
      final argumentInvocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % git c',
        terminalCursorOffset: 'tester@host ~ % git c'.length,
        shellCommand: 'zsh',
      );

      expect(argumentInvocation, isNotNull);
      expect(argumentInvocation!.commandLine, 'git c');
      expect(argumentInvocation.commandName, 'git');
      expect(argumentInvocation.shellCommand, 'zsh');
      expect(argumentInvocation.token, 'c');
      expect(argumentInvocation.tokenStart, 4);
      expect(argumentInvocation.mode, ShellCompletionMode.argument);
      expect(argumentInvocation.words, ['git', 'c']);
      expect(argumentInvocation.wordIndex, 1);
    });

    test('does not request all directories after an empty cd token', () {
      final directoryInvocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % cd ',
        terminalCursorOffset: 'tester@host ~ % cd '.length,
      );

      expect(directoryInvocation, isNull);
    });

    test('allows known fallback subcommands after an empty argument token', () {
      final invocation = buildShellCompletionInvocation(
        terminalText: 'tester@host ~ % tmux ',
        terminalCursorOffset: 'tester@host ~ % tmux '.length,
      );

      expect(invocation, isNotNull);
      expect(invocation!.commandLine, 'tmux ');
      expect(invocation.commandName, 'tmux');
      expect(invocation.token, isEmpty);
      expect(invocation.tokenStart, 5);
      expect(invocation.mode, ShellCompletionMode.argument);
      expect(invocation.words, ['tmux']);
      expect(invocation.wordIndex, 1);
    });
  });

  group('buildShellCompletionStaticSuggestions', () {
    test('builds tmux subcommand suggestions for an empty token', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'tmux ',
        cursorOffset: 5,
        token: '',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        commandName: 'tmux',
        words: ['tmux'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll',
      );

      final suggestions = buildShellCompletionStaticSuggestions(invocation);

      expect(suggestions, isNotNull);
      expect(suggestions!.take(4).map((suggestion) => suggestion.label), [
        'tmux attach',
        'tmux attach-session',
        'tmux new',
        'tmux new-session',
      ]);
      expect(suggestions.first.replacement, 'attach');
      expect(suggestions.first.replacementStart, 5);
      expect(suggestions.first.commitSuffix, ' ');
    });

    test('filters tmux subcommand suggestions as the token narrows', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'tmux a',
        cursorOffset: 6,
        token: 'a',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        commandName: 'tmux',
        words: ['tmux', 'a'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll',
      );

      final suggestions = buildShellCompletionStaticSuggestions(invocation);

      expect(suggestions!.map((suggestion) => suggestion.label), [
        'tmux attach',
        'tmux attach-session',
      ]);
    });

    test('returns null for commands without a static provider', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'git a',
        cursorOffset: 5,
        token: 'a',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        words: ['git', 'a'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll',
      );

      expect(buildShellCompletionStaticSuggestions(invocation), isNull);
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

    test('labels dynamic argument suggestions with the command context', () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'tmux a',
        cursorOffset: 6,
        token: 'a',
        tokenStart: 5,
        mode: ShellCompletionMode.argument,
        commandName: 'tmux',
        words: ['tmux', 'a'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll',
      );

      final suggestions = parseShellCompletionOutput(
        'argument\tattach',
        invocation,
      );

      expect(suggestions.single.label, 'tmux attach');
      expect(suggestions.single.replacement, 'attach');
      expect(suggestions.single.replacementStart, 5);
      expect(suggestions.single.commitSuffix, ' ');
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
      shellCommand: '/bin/zsh',
      workingDirectory: '/Users/depoll/project',
    );

    final command = buildShellCompletionRemoteCommand(invocation);

    expect(
      command,
      contains(r'flutty_shell=${FLUTTY_PREFERRED_SHELL:-${SHELL:-}}'),
    );
    expect(command, contains("export FLUTTY_MODE='command' FLUTTY_TOKEN='gi'"));
    expect(command, contains("FLUTTY_COMMAND_LINE='gi'"));
    expect(command, contains('FLUTTY_CURSOR_OFFSET=2'));
    expect(command, contains('FLUTTY_WORD_INDEX=0'));
    expect(command, contains('FLUTTY_COMP_WORDS_ASSIGNMENT='));
    expect(command, contains("FLUTTY_PREFERRED_SHELL='/bin/zsh'"));
    expect(command, contains('FLUTTY_INCLUDE_CD_SHORTCUTS=0'));
    expect(command, contains("FLUTTY_CWD='/Users/depoll/project'"));
    expect(command, contains('FLUTTY_LIMIT=96'));
    expect(command, contains(r'FLUTTY_PROFILE_KIND=$flutty_profile_kind'));
    expect(command, contains(r'source_if_readable "$HOME/.zprofile"'));
    expect(command, contains(r'source_if_readable "$HOME/.zshrc"'));
    expect(command, contains('source_if_readable /etc/bash_completion'));
    expect(command, contains(r'eval "$FLUTTY_COMP_WORDS_ASSIGNMENT"'));
    expect(command, contains(r'_completion_loader "$cmd"'));
    expect(command, contains('emit_dynamic_argument_matches'));
    expect(command, isNot(contains('zpty -b')));
    expect(command, contains(r'''printf '%s\n' "$item"'''));
    expect(command, contains(r'source_if_readable "$HOME/.bash_profile"'));
    expect(command, contains(r'emit_line command "$item" || break'));
    expect(command, contains("FLUTTY_CWD='/Users/depoll/project'"));
  });

  test(
    'interactive zsh command drives zle completions through the active shell',
    () {
      const invocation = ShellCompletionInvocation(
        commandLine: 'git c',
        cursorOffset: 5,
        token: 'c',
        tokenStart: 4,
        mode: ShellCompletionMode.argument,
        commandName: 'git',
        shellCommand: 'zsh',
        words: ['git', 'c'],
        wordIndex: 1,
        workingDirectory: '/Users/depoll/project',
      );

      final command = buildInteractiveZshCompletionRemoteCommand(invocation);
      final input = buildInteractiveZshCompletionInput(invocation);

      expect(command, contains("FLUTTY_PREFERRED_SHELL='zsh'"));
      expect(
        command,
        contains(r'flutty_shell=${FLUTTY_PREFERRED_SHELL:-${SHELL:-}}'),
      );
      expect(command, contains('stty -echo'));
      expect(command, contains("FLUTTY_MODE='argument'"));
      expect(command, contains('flutty-zsh-completion.'));
      expect(command, contains(r'source_if_readable "$HOME/.zshrc"'));
      expect(command, contains('zle -C _flutty_complete'));
      expect(command, contains('bindkey "^I" _flutty_complete'));
      expect(command, contains(r'exec "$flutty_runner" -fi'));
      expect(input, contains(r'source "$FLUTTY_ZSH_COMPLETION_SETUP"'));
      expect(input, contains('git c\t'));
      expect(command, contains('__FLUTTY_ZSH_NATIVE_DONE__'));
      expect(command, contains(r'''printf 'argument\t%s\n' "$item"'''));
    },
  );
}
