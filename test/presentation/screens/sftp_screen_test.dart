import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/remote_text_editor_screen.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

void main() {
  group('SFTP path helpers', () {
    test('parentRemotePath resolves POSIX parents', () {
      expect(parentRemotePath('/tmp/monkeyssh'), '/tmp');
      expect(parentRemotePath('/tmp'), '/');
      expect(parentRemotePath('/'), '/');
    });

    test('pushSftpPathHistory appends new locations without duplicates', () {
      expect(pushSftpPathHistory(const ['/tmp'], '/tmp'), ['/tmp']);
      expect(pushSftpPathHistory(const ['/tmp'], '/tmp/monkeyssh'), [
        '/tmp',
        '/tmp/monkeyssh',
      ]);
    });

    test('popSftpPathHistory keeps at least one history entry', () {
      expect(popSftpPathHistory(const ['/']), ['/']);
      expect(popSftpPathHistory(const ['/', '/tmp', '/tmp/monkeyssh']), [
        '/',
        '/tmp',
      ]);
    });

    test('requested directories open directly without file highlighting', () {
      expect(
        resolveRequestedSftpNavigationTarget('/var/log', isDirectory: true),
        (directoryPath: '/var/log', highlightedFileName: null),
      );
    });

    test(
      'requested files open their parent directory and highlight the file',
      () {
        expect(
          resolveRequestedSftpNavigationTarget(
            '/var/log/app.log',
            isDirectory: false,
          ),
          (directoryPath: '/var/log', highlightedFileName: 'app.log'),
        );
      },
    );

    test('scrolls upward when the highlighted file is above the viewport', () {
      expect(
        resolveSftpHighlightedFileScrollOffset(
          highlightedIndex: 2,
          currentOffset: 300,
          itemExtentEstimate: 64,
          viewportExtent: 240,
          maxScrollExtent: 2000,
        ),
        112,
      );
    });

    test(
      'scrolls downward when the highlighted file is below the viewport',
      () {
        expect(
          resolveSftpHighlightedFileScrollOffset(
            highlightedIndex: 12,
            currentOffset: 120,
            itemExtentEstimate: 64,
            viewportExtent: 240,
            maxScrollExtent: 2000,
          ),
          608,
        );
      },
    );

    test(
      'keeps the current offset when the highlighted file is already visible',
      () {
        expect(
          resolveSftpHighlightedFileScrollOffset(
            highlightedIndex: 4,
            currentOffset: 180,
            itemExtentEstimate: 64,
            viewportExtent: 240,
            maxScrollExtent: 2000,
          ),
          180,
        );
      },
    );

    test('detects previewable image file names including svg', () {
      expect(isPreviewableImageFileName('screenshot.png'), isTrue);
      expect(isPreviewableImageFileName('diagram.svg'), isTrue);
      expect(isPreviewableImageFileName('notes.txt'), isFalse);
    });

    test('detects svg file names', () {
      expect(isSvgFileName('diagram.svg'), isTrue);
      expect(isSvgFileName('diagram.SVG'), isTrue);
      expect(isSvgFileName('diagram.png'), isFalse);
    });

    test('detects video fixtures for placeholder icon coverage', () {
      expect(isVideoFileName('demo.mp4'), isTrue);
      expect(isVideoFileName('demo.MOV'), isTrue);
      expect(isVideoFileName('demo.avi'), isTrue);
      expect(isVideoFileName('demo.png'), isFalse);
      expect(
        resolveSftpFileIcon(isDirectory: false, filename: 'demo.mp4'),
        Icons.video_file,
      );
      expect(
        resolveSftpFileIcon(isDirectory: false, filename: 'diagram.svg'),
        Icons.image,
      );
    });

    test('builds shell-safe clipboard text for copied remote paths', () {
      expect(
        buildSftpCopyPathClipboardText(
          directory: '/home/demo/Project Files',
          filename: "today's notes.txt",
        ),
        r"'/home/demo/Project Files/today'\''s notes.txt'",
      );
    });

    test('blocks oversized image previews before reading remote bytes', () {
      expect(
        resolveSftpImagePreviewBlockMessage(byteCount: 10 * 1024 * 1024 + 1),
        'File is too large to preview here (max 10 MB)',
      );
      expect(
        resolveSftpImagePreviewBlockMessage(byteCount: 10 * 1024 * 1024),
        isNull,
      );
    });

    test('blocks oversized and binary text edits', () {
      expect(
        resolveSftpTextEditBlockMessage(byteCount: 1024 * 1024 + 1),
        'File is too large to edit here (max 1 MB)',
      );
      expect(
        resolveSftpTextEditBlockMessage(
          byteCount: 4,
          loadedBytes: Uint8List.fromList([0x66, 0x6f, 0x00, 0x6f]),
        ),
        'Binary files cannot be edited here',
      );
      expect(
        resolveSftpTextEditBlockMessage(
          byteCount: 5,
          loadedBytes: Uint8List.fromList('hello'.codeUnits),
        ),
        isNull,
      );
    });

    test('allows selecting multiple files for SFTP uploads', () {
      final request = resolveSftpUploadPickerRequest();

      expect(request.allowMultiple, isTrue);
      expect(request.withReadStream, isTrue);
    });

    test(
      'opens an upload stream from the picked file path when needed',
      () async {
        final tempDirectory = await Directory.systemTemp.createTemp(
          'sftp-upload-test',
        );
        addTearDown(() => tempDirectory.delete(recursive: true));

        final fileOnDisk = File('${tempDirectory.path}/notes.txt');
        await fileOnDisk.writeAsString('copilot');

        final file = PlatformFile(
          name: 'notes.txt',
          path: fileOnDisk.path,
          size: 7,
        );
        final stream = resolvePickedSftpUploadReadStream(file);

        expect(stream, isNotNull);
        expect(
          await stream!.transform(const SystemEncoding().decoder).join(),
          'copilot',
        );
      },
    );

    test('uses the file name when a single upload is unreadable', () {
      expect(
        resolveUnreadableSftpUploadMessage([
          PlatformFile(name: 'notes.txt', size: 0),
        ]),
        'Unable to read "notes.txt"',
      );
    });

    test('uses a pluralized count when multiple uploads are unreadable', () {
      expect(
        resolveUnreadableSftpUploadMessage([
          PlatformFile(name: 'notes.txt', size: 0),
          PlatformFile(name: 'todo.txt', size: 0),
        ]),
        'Unable to read 2 selected files',
      );
    });

    test('resolves directory taps as navigation', () {
      expect(
        resolveSftpFileTapIntent(isDirectory: true, filename: 'Documents'),
        SftpFileTapIntent.navigate,
      );
    });

    test('resolves image taps as preview', () {
      expect(
        resolveSftpFileTapIntent(isDirectory: false, filename: 'diagram.png'),
        SftpFileTapIntent.preview,
      );
    });

    test('resolves other file taps as edit', () {
      expect(
        resolveSftpFileTapIntent(isDirectory: false, filename: 'notes.txt'),
        SftpFileTapIntent.edit,
      );
    });

    test('measures the widest rendered line instead of the longest string', () {
      const style = TextStyle(fontSize: 20);
      const trailingSlack = 12.0;
      const textDirection = TextDirection.ltr;
      const textScaler = TextScaler.noScaling;
      const narrowerButLonger = 'iiiiiiiiii';
      const widerButShorter = 'WWWW';
      final widths = <String, double>{
        narrowerButLonger: 80,
        widerButShorter: 200,
      };

      expect(
        measureUnwrappedEditorContentWidth(
          lines: const [narrowerButLonger, widerButShorter],
          style: style,
          textDirection: textDirection,
          textScaler: textScaler,
          trailingSlack: trailingSlack,
          measureLineWidth: (line, _) => widths[line]!,
        ),
        closeTo(widths[widerButShorter]! + trailingSlack, 0.001),
      );
    });
  });
}
