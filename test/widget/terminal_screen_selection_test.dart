import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/terminal_screen.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('trimTerminalSelectionText', () {
    test('trims trailing padding on each line only', () {
      expect(
        trimTerminalSelectionText('  ls -la   \nnext line    \n    '),
        '  ls -la\nnext line\n',
      );
    });

    test('preserves interior spaces', () {
      expect(trimTerminalLinePadding('a  b   c   '), 'a  b   c');
    });
  });

  group('trimTerminalLinkCandidate', () {
    test('removes trailing punctuation around terminal links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/docs).'),
        'https://example.com/docs',
      );
    });

    test('keeps balanced parentheses inside links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path(test)'),
        'https://example.com/path(test)',
      );
    });

    test('keeps balanced square and curly brackets at the end of links', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path[tmux]'),
        'https://example.com/path[tmux]',
      );
      expect(
        trimTerminalLinkCandidate('https://example.com/path{tmux}'),
        'https://example.com/path{tmux}',
      );
    });

    test('removes unmatched trailing square and curly brackets', () {
      expect(
        trimTerminalLinkCandidate('https://example.com/path[tmux]]'),
        'https://example.com/path[tmux]',
      );
      expect(
        trimTerminalLinkCandidate('https://example.com/path{tmux}}'),
        'https://example.com/path{tmux}',
      );
    });
  });

  group('trimTerminalFilePathCandidate', () {
    test('drops stack-trace line and column suffixes', () {
      expect(
        trimTerminalFilePathCandidate('/var/log/app.log:42:7'),
        '/var/log/app.log',
      );
    });

    test('drops trailing punctuation around file paths', () {
      expect(
        trimTerminalFilePathCandidate('/var/log/app.log).'),
        '/var/log/app.log',
      );
    });

    test('drops stack-trace suffixes from relative paths too', () {
      expect(
        trimTerminalFilePathCandidate('../lib/main.dart:42:7'),
        '../lib/main.dart',
      );
    });

    test('drops view line-range suffixes from file paths', () {
      expect(
        trimTerminalFilePathCandidate(
          '~/Code/flutty.worktrees/fix-local-path-link-separators/test/widget/terminal_screen_selection_test.dartL360:430',
        ),
        '~/Code/flutty.worktrees/fix-local-path-link-separators/test/widget/terminal_screen_selection_test.dart',
      );
    });

    test('drops trailing shell operators from file paths', () {
      expect(
        trimTerminalFilePathCandidate(
          '/Users/depoll/Code/flutty.worktrees/fix-main-ci&&',
        ),
        '/Users/depoll/Code/flutty.worktrees/fix-main-ci',
      );
      expect(
        trimTerminalFilePathCandidate('/var/log/app.log||'),
        '/var/log/app.log',
      );
      expect(trimTerminalFilePathCandidate('/tmp/output;'), '/tmp/output');
    });

    test('drops wrapped result-count suffixes after unmatched parentheses', () {
      expect(
        trimTerminalFilePathCandidate(
          '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/test/widget/terminal_text_input_handler_test.dart)6',
        ),
        '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/test/widget/terminal_text_input_handler_test.dart',
      );
    });

    test('drops wrapped result-count suffixes from dotless explicit paths', () {
      expect(trimTerminalFilePathCandidate('/etc/hosts)6'), '/etc/hosts');
      expect(trimTerminalFilePathCandidate('~/README)6'), '~/README');
    });
  });

  group('resolveTerminalFilePathVerificationCandidates', () {
    test(
      'offers shorter known-extension parses for ambiguous explicit paths',
      () {
        expect(
          resolveTerminalFilePathVerificationCandidates(
            '/srv/app/lib/main.dartlines',
          ),
          ['/srv/app/lib/main.dartlines', '/srv/app/lib/main.dart'],
        );
      },
    );

    test('leaves ordinary explicit paths unchanged', () {
      expect(
        resolveTerminalFilePathVerificationCandidates('/srv/app/lib/main.dart'),
        ['/srv/app/lib/main.dart'],
      );
    });
  });

  group('resolvePickedTerminalUploadFileName', () {
    test('prefers the picker-provided name when present', () {
      final file = PlatformFile(name: 'Screenshot.png', size: 0);

      expect(resolvePickedTerminalUploadFileName(file), 'Screenshot.png');
    });

    test('falls back to the local path basename when needed', () {
      final file = PlatformFile(
        name: '   ',
        path: '/tmp/copilot/screenshot.png',
        size: 0,
      );

      expect(resolvePickedTerminalUploadFileName(file), 'screenshot.png');
    });

    test('uses a stable generated fallback when no name is available', () {
      final file = PlatformFile(name: '', size: 0);

      expect(
        resolvePickedTerminalUploadFileName(file, index: 2),
        'selected-file-3',
      );
    });
  });

  group('resolvePickedTerminalUploadReadStream', () {
    test('opens a stream from the picked file path when needed', () async {
      final tempDirectory = await Directory.systemTemp.createTemp(
        'terminal-upload-test',
      );
      addTearDown(() => tempDirectory.delete(recursive: true));

      final fileOnDisk = File('${tempDirectory.path}/notes.txt');
      await fileOnDisk.writeAsString('copilot');

      final file = PlatformFile(
        name: 'notes.txt',
        path: fileOnDisk.path,
        size: 7,
      );
      final stream = resolvePickedTerminalUploadReadStream(file);

      expect(stream, isNotNull);
      expect(
        await stream!.transform(const SystemEncoding().decoder).join(),
        'copilot',
      );
    });
  });

  group('resolveTerminalUploadPickerRequest', () {
    test('allows selecting multiple images for terminal uploads', () {
      final request = resolveTerminalUploadPickerRequest(images: true);

      expect(request.dialogTitle, 'Select images to upload');
      expect(request.pickerType, FileType.image);
      expect(request.itemLabelSingular, 'image');
      expect(request.itemLabelPlural, 'images');
      expect(request.allowMultiple, isTrue);
      expect(request.failureContext, 'Image picker upload');
    });

    test('allows selecting multiple files for terminal uploads', () {
      final request = resolveTerminalUploadPickerRequest(images: false);

      expect(request.dialogTitle, 'Select files to upload');
      expect(request.pickerType, FileType.any);
      expect(request.itemLabelSingular, 'file');
      expect(request.itemLabelPlural, 'files');
      expect(request.allowMultiple, isTrue);
      expect(request.failureContext, 'File picker upload');
    });
  });

  group('detectTerminalFilePaths', () {
    test('returns supported file path ranges in text order', () {
      const text =
          'Open /var/log/app.log:42:7 and lib/main.dart but not feature/sftp-browser';
      final detectedPaths = detectTerminalFilePaths(text);

      expect(detectedPaths.map((path) => path.path).toList(), [
        '/var/log/app.log',
        'lib/main.dart',
      ]);
      expect(detectedPaths.map((path) => path.start).toList(), [
        text.indexOf('/var/log/app.log'),
        text.indexOf('lib/main.dart'),
      ]);
      expect(
        text.substring(detectedPaths.first.start, detectedPaths.first.end),
        '/var/log/app.log',
      );
    });
  });

  group('detectTerminalLinkAtTextOffset', () {
    test('detects an https link at the tapped offset', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Visit https://example.com/docs for details.',
        12,
      );

      expect(detectedLink, isNotNull);
      expect(detectedLink!.uri.toString(), 'https://example.com/docs');
    });

    test('normalizes case-insensitive www links to https', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Open WWW.github.com/features/copilot now',
        10,
      );

      expect(detectedLink, isNotNull);
      expect(
        detectedLink!.uri.toString(),
        'https://www.github.com/features/copilot',
      );
    });

    test('returns null when the tapped offset is outside a link', () {
      expect(
        detectTerminalLinkAtTextOffset(
          'Visit https://example.com/docs for details.',
          2,
        ),
        isNull,
      );
    });

    test('detects visible tel links at the tapped offset', () {
      final detectedLink = detectTerminalLinkAtTextOffset(
        'Call tel:+15551234567 for help.',
        10,
      );

      expect(detectedLink, isNotNull);
      expect(detectedLink!.uri.toString(), 'tel:+15551234567');
    });
  });

  group('detectTerminalFilePathAtTextOffset', () {
    test('detects an absolute remote path at the tapped offset', () {
      final detectedPath = detectTerminalFilePathAtTextOffset(
        'Open /var/log/nginx/access.log in SFTP.',
        12,
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '/var/log/nginx/access.log');
    });

    test('detects tilde-prefixed paths at the tapped offset', () {
      final detectedPath = detectTerminalFilePathAtTextOffset(
        'Open ~/.config/ghostty/config in SFTP.',
        10,
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '~/.config/ghostty/config');
    });

    test('normalizes stack-trace line suffixes before navigation', () {
      final detectedPath = detectTerminalFilePathAtTextOffset(
        'Error in /srv/app/lib/main.dart:42:7',
        15,
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '/srv/app/lib/main.dart');
    });

    test('detects absolute paths split across wrapped lines', () {
      const text =
          'Open /srv/app/lib/presentation/screens/\nterminal_screen.dart next.';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_screen'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/srv/app/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects paths split across indented continuation lines', () {
      const text =
          'Open /srv/app/lib/presentation/\n'
          '    screens/terminal_screen.dart next.';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('screens'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/srv/app/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('ignores colored guide prefixes in continuation indentation', () {
      const text =
          'Open /srv/app/lib/presentation/\n'
          '│   screens/terminal_screen.dart next.';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('screens'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/srv/app/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects paths split across TUI guide continuation rows', () {
      const text =
          "│ p = Path('/Users/depoll/.copilot/session-state/6745\n"
          "  │ 9a12-f8a8-405a-a838-2fc3a30dadd4/plan.md')";
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('9a12'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/Users/depoll/.copilot/session-state/67459a12-f8a8-405a-a838-2fc3a30dadd4/plan.md',
      );
    });

    test('detects tilde paths split across TUI guide continuation rows', () {
      const text =
          '│ Edit ~/Code/flutty.worktrees/fix-local-path-link-sepa\n'
          '  │ rators/lib/presentation/screens/terminal_screen.dart';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('rators'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-local-path-link-separators/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects tilde paths split across unindented continuation lines', () {
      const text =
          'Edit ~/Code/flutty.worktrees/fix-sftp-local-path-link\n'
          's/lib/presentation/screens/terminal_screen.dart';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_screen'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-sftp-local-path-links/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('detects local paths split across three wrapped lines', () {
      const text =
          'Read ~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/\n'
          'presentation/widgets/terminal_text_input_handler.dar\n'
          't';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.lastIndexOf('t'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/presentation/widgets/terminal_text_input_handler.dart',
      );
    });

    test('detects local paths split across three TUI continuation rows', () {
      const text =
          '│ Read ~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/\n'
          '│ presentation/widgets/terminal_text_input_handler.dar\n'
          '│ t';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.lastIndexOf('t'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/presentation/widgets/terminal_text_input_handler.dart',
      );
    });

    test('drops wrapped result counts from grep-style file path matches', () {
      const text =
          '(~/Code/flutty.worktrees/fix-swipe-keyboard-typing/test/\n'
          'widget/terminal_text_input_handler_test.dart)6 lines found';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_text_input_handler_test.dart'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/test/widget/terminal_text_input_handler_test.dart',
      );
    });

    test('keeps suffix taps inside the hit-test range for stack traces', () {
      const line = 'Error in /srv/app/lib/main.dart:42:7';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        line,
        line.indexOf('42'),
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '/srv/app/lib/main.dart');
      expect(
        line.substring(detectedPath.start, detectedPath.end),
        '/srv/app/lib/main.dart',
      );
    });

    test('ignores plain filenames without any path context', () {
      expect(
        detectTerminalFilePathAtTextOffset('Inspect main.dart next.', 12),
        isNull,
      );
    });

    test(
      'detects verified-looking relative paths with file-like basenames',
      () {
        final detectedPath = detectTerminalFilePathAtTextOffset(
          'Inspect lib/presentation/screens/terminal_screen.dart next.',
          12,
        );

        expect(detectedPath, isNotNull);
        expect(
          detectedPath!.path,
          'lib/presentation/screens/terminal_screen.dart',
        );
      },
    );

    test('detects dot-relative paths', () {
      final detectedPath = detectTerminalFilePathAtTextOffset(
        'Inspect ../lib/main.dart next.',
        12,
      );

      expect(detectedPath, isNotNull);
      expect(detectedPath!.path, '../lib/main.dart');
    });

    test('stops before shell operators that follow a wrapped path', () {
      const text =
          'cd /Users/depoll/Code/flutty.worktrees/fix-main-ci&& git status';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('fix-main-ci'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '/Users/depoll/Code/flutty.worktrees/fix-main-ci',
      );
      expect(
        text.substring(detectedPath.start, detectedPath.end),
        '/Users/depoll/Code/flutty.worktrees/fix-main-ci',
      );
    });

    test('drops wrapped view line-range suffixes from detected paths', () {
      const text =
          '~/Code/flutty.worktrees/fix-local-path-link-separators/'
          'lib/presentation/screens/terminal_screen.dartL360:430';
      final detectedPath = detectTerminalFilePathAtTextOffset(
        text,
        text.indexOf('terminal_screen'),
      );

      expect(detectedPath, isNotNull);
      expect(
        detectedPath!.path,
        '~/Code/flutty.worktrees/fix-local-path-link-separators/lib/presentation/screens/terminal_screen.dart',
      );
    });

    test('ignores branch-like slash paths without a file-like basename', () {
      expect(
        detectTerminalFilePathAtTextOffset(
          'Inspect feature/sftp-browser next.',
          12,
        ),
        isNull,
      );
    });

    test('returns null when the tapped offset is outside the path', () {
      expect(
        detectTerminalFilePathAtTextOffset(
          'Open /var/log/nginx/access.log in SFTP.',
          2,
        ),
        isNull,
      );
    });
  });

  group('resolveTerminalFilePathSegmentOnRow', () {
    test('excludes continuation indentation from the visible segment', () {
      const snapshotText =
          'Open /srv/app/lib/presentation/\n'
          '    screens/terminal_screen.dart next.';
      const rowText = '    screens/terminal_screen.dart next.';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.indexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path: '/srv/app/lib/presentation/screens/terminal_screen.dart',
        ),
        (text: 'screens/terminal_screen.dart', startColumn: 4, endColumn: 31),
      );
    });

    test('excludes TUI guide prefixes from wrapped visible segments', () {
      const snapshotText =
          "│ p = Path('/Users/depoll/.copilot/session-state/6745\n"
          "  │ 9a12-f8a8-405a-a838-2fc3a30dadd4/plan.md')";
      const rowText = '  │ 9a12-f8a8-405a-a838-2fc3a30dadd4/plan.md\')';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.indexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path:
              '/Users/depoll/.copilot/session-state/67459a12-f8a8-405a-a838-2fc3a30dadd4/plan.md',
        ),
        (
          text: '9a12-f8a8-405a-a838-2fc3a30dadd4/plan.md',
          startColumn: 4,
          endColumn: 43,
        ),
      );
    });

    test('excludes guide prefixes from wrapped tilde path segments', () {
      const snapshotText =
          '│ Edit ~/Code/flutty.worktrees/fix-local-path-link-sepa\n'
          '  │ rators/lib/presentation/screens/terminal_screen.dart';
      const rowText =
          '  │ rators/lib/presentation/screens/terminal_screen.dart';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.indexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path:
              '~/Code/flutty.worktrees/fix-local-path-link-separators/lib/presentation/screens/terminal_screen.dart',
        ),
        (
          text: 'rators/lib/presentation/screens/terminal_screen.dart',
          startColumn: 4,
          endColumn: 55,
        ),
      );
    });

    test(
      'keeps unindented continuation rows anchored to the first path cell',
      () {
        const snapshotText =
            'Edit ~/Code/flutty.worktrees/fix-sftp-local-path-link\n'
            's/lib/presentation/screens/terminal_screen.dart';
        const rowText = 's/lib/presentation/screens/terminal_screen.dart';
        expect(
          resolveTerminalFilePathSegmentOnRowForPath(
            snapshotText: snapshotText,
            rowText: rowText,
            rowStartOffset: snapshotText.indexOf(rowText),
            rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
            path:
                '~/Code/flutty.worktrees/fix-sftp-local-path-links/lib/presentation/screens/terminal_screen.dart',
          ),
          (
            text: 's/lib/presentation/screens/terminal_screen.dart',
            startColumn: 0,
            endColumn: 46,
          ),
        );
      },
    );

    test('resolves single-character third-line path continuations', () {
      const snapshotText =
          'Read ~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/\n'
          'presentation/widgets/terminal_text_input_handler.dar\n'
          't';
      const rowText = 't';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.lastIndexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path:
              '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/presentation/widgets/terminal_text_input_handler.dart',
        ),
        (text: 't', startColumn: 0, endColumn: 0),
      );
    });

    test('resolves guided single-character third-line path continuations', () {
      const snapshotText =
          '│ Read ~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/\n'
          '│ presentation/widgets/terminal_text_input_handler.dar\n'
          '│ t';
      const rowText = '│ t';
      expect(
        resolveTerminalFilePathSegmentOnRowForPath(
          snapshotText: snapshotText,
          rowText: rowText,
          rowStartOffset: snapshotText.lastIndexOf(rowText),
          rowColumnOffsets: List<int>.generate(rowText.length + 1, (i) => i),
          path:
              '~/Code/flutty.worktrees/fix-swipe-keyboard-typing/lib/presentation/widgets/terminal_text_input_handler.dart',
        ),
        (text: 't', startColumn: 2, endColumn: 2),
      );
    });
  });

  group('normalizeTerminalLinkCandidate', () {
    test('prepends https for uppercase www links', () {
      expect(
        normalizeTerminalLinkCandidate('WWW.example.com/docs'),
        'https://WWW.example.com/docs',
      );
    });
  });

  group('isLaunchableTerminalUri', () {
    test('allows supported external link schemes', () {
      expect(isLaunchableTerminalUri(Uri.parse('https://example.com')), isTrue);
      expect(
        isLaunchableTerminalUri(Uri.parse('mailto:test@example.com')),
        isTrue,
      );
      expect(isLaunchableTerminalUri(Uri.parse('tel:+15551234567')), isTrue);
    });

    test('rejects unsupported schemes', () {
      expect(
        isLaunchableTerminalUri(Uri.parse('file:///tmp/test.txt')),
        isFalse,
      );
      expect(
        isLaunchableTerminalUri(Uri.parse('intent://example.com')),
        isFalse,
      );
    });
  });

  group('isSupportedTerminalFilePath', () {
    test('allows explicit paths and conservative relative file paths', () {
      expect(isSupportedTerminalFilePath('/var/log/app.log'), isTrue);
      expect(isSupportedTerminalFilePath('~/.ssh/config'), isTrue);
      expect(isSupportedTerminalFilePath('lib/main.dart'), isTrue);
      expect(isSupportedTerminalFilePath('../lib/main.dart'), isTrue);
      expect(isSupportedTerminalFilePath('feature/sftp-browser'), isFalse);
      expect(isSupportedTerminalFilePath('//example.com/path'), isFalse);
    });
  });

  group('shouldActivateTerminalFilePath', () {
    test('activates unambiguous explicit paths without verification', () {
      expect(
        shouldActivateTerminalFilePath(
          '/var/log/app.log',
          hasVerifiedPath: false,
        ),
        isTrue,
      );
      expect(
        shouldActivateTerminalFilePath('~/.ssh/config', hasVerifiedPath: false),
        isTrue,
      );
    });

    test('only activates ambiguous slash commands after verification', () {
      expect(
        shouldActivateTerminalFilePath('/commands', hasVerifiedPath: false),
        isFalse,
      );
      expect(
        shouldActivateTerminalFilePath('/commands', hasVerifiedPath: true),
        isTrue,
      );
    });

    test('only activates ambiguous explicit paths after verification', () {
      expect(
        hasAmbiguousTerminalFilePathParsing('/srv/app/lib/main.dartlines'),
        isTrue,
      );
      expect(
        shouldActivateTerminalFilePath(
          '/srv/app/lib/main.dartlines',
          hasVerifiedPath: false,
        ),
        isFalse,
      );
      expect(
        shouldActivateTerminalFilePath(
          '/srv/app/lib/main.dartlines',
          hasVerifiedPath: true,
        ),
        isTrue,
      );
    });

    test('only activates conservative relative paths after verification', () {
      expect(
        shouldActivateTerminalFilePath('lib/main.dart', hasVerifiedPath: false),
        isFalse,
      );
      expect(
        shouldActivateTerminalFilePath('lib/main.dart', hasVerifiedPath: true),
        isTrue,
      );
      expect(
        shouldActivateTerminalFilePath(
          '../lib/main.dart',
          hasVerifiedPath: false,
        ),
        isFalse,
      );
      expect(
        shouldActivateTerminalFilePath(
          '../lib/main.dart',
          hasVerifiedPath: true,
        ),
        isTrue,
      );
    });
  });

  group('resolveForgivingTerminalTapOffsets', () {
    test('checks nearby horizontal and adjacent-row cells first', () {
      expect(
        resolveForgivingTerminalTapOffsets(const CellOffset(10, 5)).take(8),
        const [
          CellOffset(10, 5),
          CellOffset(9, 5),
          CellOffset(11, 5),
          CellOffset(8, 5),
          CellOffset(12, 5),
          CellOffset(7, 5),
          CellOffset(13, 5),
          CellOffset(6, 5),
        ],
      );
    });
  });

  group('resolveVisibleTerminalRowRange', () {
    test('uses rendered viewport height to cover all visible rows', () {
      expect(
        resolveVisibleTerminalRowRange(
          scrollOffset: 24,
          lineHeight: 12,
          viewportHeight: 72,
          bufferHeight: 200,
        ),
        (topRow: 2, bottomRow: 7),
      );
    });

    test('returns null when layout metrics are not ready', () {
      expect(
        resolveVisibleTerminalRowRange(
          scrollOffset: 0,
          lineHeight: 0,
          viewportHeight: 72,
          bufferHeight: 200,
        ),
        isNull,
      );
      expect(
        resolveVisibleTerminalRowRange(
          scrollOffset: 0,
          lineHeight: 12,
          viewportHeight: 0,
          bufferHeight: 200,
        ),
        isNull,
      );
    });
  });

  group('resolveTerminalPathUnderlineRect', () {
    test('places the underline at the bottom of the rendered row', () {
      expect(
        resolveTerminalPathUnderlineRect(
          lineTopLeft: const Offset(24, 18),
          lineEndOffset: const Offset(104, 18),
          lineHeight: 20,
          viewportHeight: 300,
        ),
        const Rect.fromLTWH(24, 35.9, 80, 1.6),
      );
    });

    test(
      'uses the rendered row height when it is taller than the line height',
      () {
        expect(
          resolveTerminalPathUnderlineRect(
            lineTopLeft: const Offset(24, 18),
            lineEndOffset: const Offset(104, 18),
            lineHeight: 20,
            rowHeight: 24,
            viewportHeight: 300,
          ),
          const Rect.fromLTWH(24, 39.58, 80, 1.92),
        );
      },
    );

    test('prefers measured text height when available', () {
      expect(
        resolveTerminalPathUnderlineRect(
          lineTopLeft: const Offset(24, 18),
          lineEndOffset: const Offset(98, 18),
          lineHeight: 20,
          rowHeight: 24,
          textHeight: 16,
          viewportHeight: 300,
        ),
        const Rect.fromLTWH(24, 34.25, 74, 1.28),
      );
    });

    test('scales underline thickness down for smaller terminal text', () {
      expect(
        resolveTerminalPathUnderlineRect(
          lineTopLeft: const Offset(24, 18),
          lineEndOffset: const Offset(104, 18),
          lineHeight: 12,
          viewportHeight: 300,
        ),
        const Rect.fromLTWH(24, 28.54, 80, 0.96),
      );
    });

    test('scales underline thickness up for larger terminal text', () {
      expect(
        resolveTerminalPathUnderlineRect(
          lineTopLeft: const Offset(24, 18),
          lineEndOffset: const Offset(104, 18),
          lineHeight: 32,
          viewportHeight: 300,
        ),
        const Rect.fromLTWH(24, 47, 80, 2.5),
      );
    });

    test('returns null when the underline would have no visible width', () {
      expect(
        resolveTerminalPathUnderlineRect(
          lineTopLeft: const Offset(24, 18),
          lineEndOffset: const Offset(24, 18),
          lineHeight: 20,
          viewportHeight: 300,
        ),
        isNull,
      );
    });
  });

  group('isTerminalPathContinuationAcrossLines', () {
    test('joins explicit paths split by unindented rendered line breaks', () {
      expect(
        isTerminalPathContinuationAcrossLines(
          previousLineText:
              'Edit ~/Code/flutty.worktrees/fix-sftp-local-path-link',
          nextLineText: 's/lib/presentation/screens/terminal_screen.dart',
        ),
        isTrue,
      );
    });

    test('does not join unrelated rendered lines', () {
      expect(
        isTerminalPathContinuationAcrossLines(
          previousLineText: 'Read terminal_screen.dart',
          nextLineText: 'Read sftp_screen.dart',
        ),
        isFalse,
      );
    });
  });

  group('resolveTerminalPathTouchTargetRect', () {
    test('covers the path text with nearby padding', () {
      expect(
        resolveTerminalPathTouchTargetRect(
          lineTopLeft: const Offset(24, 18),
          lineEndOffset: const Offset(104, 18),
          lineHeight: 20,
          viewportHeight: 300,
        ),
        const Rect.fromLTRB(14, 10, 114, 46),
      );
    });
  });

  group('resolveTerminalPathTouchTargetTap', () {
    test('matches touches on the text and nearby surrounding space', () {
      expect(
        resolveTerminalPathTouchTargetTap(const Offset(18, 30), const [
          (path: '/var/log/app.log', touchRect: Rect.fromLTRB(14, 10, 114, 46)),
        ]),
        '/var/log/app.log',
      );
    });

    test('ignores touches outside every touch target', () {
      expect(
        resolveTerminalPathTouchTargetTap(const Offset(160, 80), const [
          (path: '/var/log/app.log', touchRect: Rect.fromLTRB(14, 10, 114, 46)),
        ]),
        isNull,
      );
    });
  });

  group('shouldResolveTerminalTapLinks', () {
    test('allows link taps when the native selection overlay is hidden', () {
      expect(
        shouldResolveTerminalTapLinks(showsNativeSelectionOverlay: false),
        isTrue,
      );
    });

    test('blocks link taps while the native selection overlay is visible', () {
      expect(
        shouldResolveTerminalTapLinks(showsNativeSelectionOverlay: true),
        isFalse,
      );
    });
  });

  group('selectedNativeOverlayText', () {
    test('returns the selected overlay substring', () {
      expect(
        selectedNativeOverlayText(
          const TextEditingValue(
            text: 'copilot cli',
            selection: TextSelection(baseOffset: 0, extentOffset: 7),
          ),
        ),
        'copilot',
      );
    });

    test('returns empty text for a collapsed overlay selection', () {
      expect(
        selectedNativeOverlayText(
          const TextEditingValue(
            text: 'copilot cli',
            selection: TextSelection.collapsed(offset: 7),
          ),
        ),
        isEmpty,
      );
    });
  });

  group('applyTerminalCursorInsertion', () {
    test('appends inserted text at the current cursor offset', () {
      final nextValue = applyTerminalCursorInsertion(
        currentText: 'echo ready &',
        cursorOffset: 12,
        insertedText: ' echo done',
      );

      expect(nextValue, 'echo ready & echo done');
    });

    test('inserts text in the middle of the current terminal input', () {
      final nextValue = applyTerminalCursorInsertion(
        currentText: 'echo done',
        cursorOffset: 5,
        insertedText: 'ready && ',
      );

      expect(nextValue, 'echo ready && done');
    });
  });

  group('applyTerminalInputDelta', () {
    test('applies backspaces before inserting committed text', () {
      expect(
        applyTerminalInputDelta(
          currentText: 'teh ',
          cursorOffset: 4,
          deletedCount: 3,
          appendedText: 'he ',
        ),
        'the ',
      );
    });
  });

  group('resolveTerminalLineSnapshotTextLength', () {
    test('preserves trailing spaces through the cursor offset', () {
      expect(
        resolveTerminalLineSnapshotTextLength(
          text: 'cat     ',
          preserveOffset: 4,
          preserveTrailingPadding: false,
        ),
        4,
      );
    });

    test('keeps full wrapped-row padding when requested', () {
      expect(
        resolveTerminalLineSnapshotTextLength(
          text: 'cat     ',
          preserveOffset: 0,
          preserveTrailingPadding: true,
        ),
        8,
      );
    });
  });

  group('shouldShowNativeSelectionOverlay', () {
    test('keeps overlay hidden until native selection mode is entered', () {
      expect(
        shouldShowNativeSelectionOverlay(
          isNativeSelectionMode: false,
          routesTouchScrollToTerminal: false,
          revealOverlayInTouchScrollMode: false,
        ),
        isFalse,
      );
    });

    test(
      'shows overlay when touch scrolling is not routed to the terminal',
      () {
        expect(
          shouldShowNativeSelectionOverlay(
            isNativeSelectionMode: true,
            routesTouchScrollToTerminal: false,
            revealOverlayInTouchScrollMode: false,
          ),
          isTrue,
        );
      },
    );

    test(
      'shows overlay during tmux touch scrolling after selection begins',
      () {
        expect(
          shouldShowNativeSelectionOverlay(
            isNativeSelectionMode: true,
            routesTouchScrollToTerminal: true,
            revealOverlayInTouchScrollMode: true,
          ),
          isTrue,
        );
      },
    );

    test(
      'keeps overlay hidden during tmux touch scrolling until selection',
      () {
        expect(
          shouldShowNativeSelectionOverlay(
            isNativeSelectionMode: true,
            routesTouchScrollToTerminal: true,
            revealOverlayInTouchScrollMode: false,
          ),
          isFalse,
        );
      },
    );
  });

  group('resolveNativeSelectionOverlayChange', () {
    test('exits mobile selection mode when selection collapses', () {
      expect(
        resolveNativeSelectionOverlayChange(
          isMobilePlatform: true,
          isNativeSelectionMode: true,
          revealOverlayInTouchScrollMode: false,
          selection: const TextSelection.collapsed(offset: 3),
        ),
        NativeSelectionOverlayChange.exitSelectionMode,
      );
    });

    test('hides only the temporary tmux overlay when selection collapses', () {
      expect(
        resolveNativeSelectionOverlayChange(
          isMobilePlatform: true,
          isNativeSelectionMode: true,
          revealOverlayInTouchScrollMode: true,
          selection: const TextSelection.collapsed(offset: 3),
        ),
        NativeSelectionOverlayChange.hideTemporaryOverlay,
      );
    });

    test('keeps overlay state when selection remains expanded', () {
      expect(
        resolveNativeSelectionOverlayChange(
          isMobilePlatform: true,
          isNativeSelectionMode: true,
          revealOverlayInTouchScrollMode: false,
          selection: const TextSelection(baseOffset: 1, extentOffset: 4),
        ),
        NativeSelectionOverlayChange.none,
      );
    });
  });
}
