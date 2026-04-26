import 'dart:async';
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

    test('detects previewable video file names', () {
      expect(isPreviewableVideoFileName('screen-recording.mp4'), isTrue);
      expect(isPreviewableVideoFileName('clip.MOV'), isTrue);
      expect(isPreviewableVideoFileName('capture.m4v'), isTrue);
      expect(isPreviewableVideoFileName('browser.webm'), isTrue);
      expect(isPreviewableVideoFileName('notes.txt'), isFalse);
    });

    test('resolves video MIME candidates from file names', () {
      expect(remoteVideoMimeTypeForFileName('recording.mp4'), 'video/mp4');
      expect(
        remoteVideoMimeTypeForFileName('recording.mov'),
        'video/quicktime',
      );
      expect(remoteVideoMimeTypeForFileName('recording.m4v'), 'video/x-m4v');
      expect(remoteVideoMimeTypeForFileName('recording.webm'), 'video/webm');
      expect(remoteVideoMimeTypeForFileName('notes.txt'), isNull);
    });

    test('rejects known oversized video previews', () {
      expect(
        isRemoteVideoPreviewSizeAllowed(maxRemoteVideoPreviewBytes),
        isTrue,
      );
      expect(
        isRemoteVideoPreviewSizeAllowed(maxRemoteVideoPreviewBytes + 1),
        isFalse,
      );

      expect(
        remoteVideoPreviewTooLargeMessage(
          sizeBytes: maxRemoteVideoPreviewBytes + 1,
        ),
        allOf(
          contains('Video is too large to preview here'),
          contains('100.0 MB'),
          contains('Download it instead'),
        ),
      );
    });

    test('detects streaming video preview byte cap overflow', () {
      expect(
        wouldRemoteVideoPreviewExceedByteCap(
          downloadedBytes: maxRemoteVideoPreviewBytes - 1,
          chunkBytes: 1,
        ),
        isFalse,
      );
      expect(
        wouldRemoteVideoPreviewExceedByteCap(
          downloadedBytes: maxRemoteVideoPreviewBytes,
          chunkBytes: 1,
        ),
        isTrue,
      );
    });

    test('detects svg file names', () {
      expect(isSvgFileName('diagram.svg'), isTrue);
      expect(isSvgFileName('diagram.SVG'), isTrue);
      expect(isSvgFileName('diagram.png'), isFalse);
    });

    test('detects video fixtures for placeholder icon coverage', () {
      expect(isPreviewableVideoFileName('demo.mp4'), isTrue);
      expect(isPreviewableVideoFileName('demo.MOV'), isTrue);
      expect(isPreviewableVideoFileName('demo.webm'), isTrue);
      expect(isPreviewableVideoFileName('demo.avi'), isFalse);
      expect(isPreviewableVideoFileName('demo.png'), isFalse);
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

    test('validates new folder names before creating directories', () {
      expect(validateSftpDirectoryName(''), 'Folder name is required');
      expect(validateSftpDirectoryName('  '), 'Folder name is required');
      expect(
        validateSftpDirectoryName('nested/folder'),
        'Folder name cannot contain /',
      );
      expect(
        validateSftpDirectoryName('..'),
        'Choose a folder name, not a navigation shortcut',
      );
      expect(validateSftpDirectoryName('release'), isNull);
    });

    test('includes remote paths in copy and create feedback', () {
      expect(
        sftpCopyPathSnackBarMessage('/var/www/site config'),
        'Copied shell-safe path for "/var/www/site config"',
      );
      expect(
        sftpCreatedDirectorySnackBarMessage('/var/www/releases'),
        'Created folder "/var/www/releases"',
      );
    });

    test('bounds stale SFTP operations with a timeout', () async {
      final completer = Completer<String>();

      await expectLater(
        withSftpOperationTimeout(
          completer.future,
          timeout: const Duration(milliseconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('describes stale SFTP timeout recovery', () {
      expect(
        sftpTimeoutMessage('listing "/home/demo"'),
        'Timed out listing "/home/demo". The SSH connection may be stale; reconnect and try again.',
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

    test('resolves video taps as video preview', () {
      expect(
        resolveSftpFileTapIntent(
          isDirectory: false,
          filename: 'screen-recording.mp4',
        ),
        SftpFileTapIntent.previewVideo,
      );
    });

    test('resolves preview kind for row action availability', () {
      expect(
        resolveSftpPreviewKind(isDirectory: true, filename: 'clip.mp4'),
        isNull,
      );
      expect(
        resolveSftpPreviewKind(isDirectory: false, filename: 'diagram.png'),
        SftpPreviewKind.image,
      );
      expect(
        resolveSftpPreviewKind(isDirectory: false, filename: 'clip.webm'),
        SftpPreviewKind.video,
      );
      expect(
        resolveSftpPreviewKind(isDirectory: false, filename: 'notes.txt'),
        isNull,
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

    testWidgets('video preview errors show metadata and fallback actions', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: buildRemoteVideoPreviewErrorForTesting(
            fileName: 'screen-recording.mp4',
            remotePath: '/home/depoll/screen-recording.mp4',
            localPath: 'build/sftp-video-preview-test/screen-recording.mp4',
            errorMessage: 'Unsupported codec',
            sizeBytes: 42,
            modifiedAt: DateTime.utc(2024, 1, 2, 3, 4, 5),
            mimeType: 'video/mp4',
          ),
        ),
      );

      expect(find.text('Could not play video preview'), findsOneWidget);
      expect(find.text('Unsupported codec'), findsOneWidget);
      expect(find.text('/home/depoll/screen-recording.mp4'), findsOneWidget);
      expect(find.text('42 B'), findsOneWidget);
      expect(find.text('video/mp4'), findsOneWidget);
      expect(find.text('Cached copy'), findsOneWidget);
      expect(find.text('Save copy'), findsOneWidget);
      expect(find.text('Open/Share'), findsOneWidget);
    });

    testWidgets('video preview deletes cached files when closed', (
      tester,
    ) async {
      final cacheDirectory = Directory('build/sftp-video-preview-test')
        ..createSync(recursive: true);
      addTearDown(() {
        if (cacheDirectory.existsSync()) {
          cacheDirectory.deleteSync(recursive: true);
        }
      });

      final cachedFile = File('${cacheDirectory.path}/cached-preview.mp4')
        ..writeAsBytesSync([1, 2, 3]);

      await tester.pumpWidget(
        MaterialApp(
          home: buildRemoteVideoPreviewErrorForTesting(
            fileName: 'cached-preview.mp4',
            remotePath: '/home/depoll/cached-preview.mp4',
            localPath: cachedFile.path,
            errorMessage: 'Unsupported codec',
            sizeBytes: 3,
            mimeType: 'video/mp4',
          ),
        ),
      );

      expect(cachedFile.existsSync(), isTrue);

      await tester.pumpWidget(const SizedBox.shrink());

      expect(cachedFile.existsSync(), isFalse);
    });
  });
}
