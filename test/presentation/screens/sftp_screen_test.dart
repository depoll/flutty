import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/models/monetization.dart';
import 'package:monkeyssh/domain/services/monetization_service.dart';
import 'package:monkeyssh/domain/services/ssh_service.dart';
import 'package:monkeyssh/presentation/models/app_platform_file.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

const _proMonetizationState = MonetizationState(
  billingAvailability: MonetizationBillingAvailability.available,
  entitlements: MonetizationEntitlements.pro(),
  offers: [],
  debugUnlockAvailable: false,
  debugUnlocked: false,
);

final _onePixelPngBytes = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/luzp0wAAAABJRU5ErkJggg==',
  ),
);

class _MockSshClient extends Mock implements SSHClient {
  @override
  Future<void> close() async {}
}

Future<void> _completeSftpClose(Invocation _) async {}

class _MockSftpClient extends Mock implements SftpClient {
  _MockSftpClient() {
    when(close).thenAnswer(_completeSftpClose);
  }
}

class _MockSftpFile extends Mock implements SftpFile {}

class _MockMonetizationService extends Mock implements MonetizationService {}

class _TestActiveSessionsNotifier extends ActiveSessionsNotifier {
  _TestActiveSessionsNotifier(this.session);

  final SshSession session;

  @override
  Map<int, SshConnectionState> build() => <int, SshConnectionState>{
    session.connectionId: SshConnectionState.connected,
  };

  @override
  SshSession? getSession(int connectionId) =>
      connectionId == session.connectionId ? session : null;

  @override
  Future<void> syncBackgroundStatus() async {}
}

Widget _buildSftpTestApp({
  required SshSession session,
  required MonetizationService monetizationService,
  required Widget child,
}) => ProviderScope(
  overrides: [
    activeSessionsProvider.overrideWith(
      () => _TestActiveSessionsNotifier(session),
    ),
    monetizationServiceProvider.overrideWithValue(monetizationService),
    monetizationStateProvider.overrideWith(
      (ref) => Stream.value(_proMonetizationState),
    ),
  ],
  child: MaterialApp(home: child),
);

SftpFileAttrs _fileAttrs({int? size}) =>
    SftpFileAttrs(size: size, mode: const SftpFileMode.value(1 << 15));

SftpName _fileEntry(String name, {int? size}) => SftpName(
  filename: name,
  longname: name,
  attr: _fileAttrs(size: size),
);

class _SftpSelectionHost extends StatefulWidget {
  const _SftpSelectionHost({
    required this.hostId,
    required this.connectionId,
    required this.constraints,
  });

  final int hostId;
  final int connectionId;
  final RemoteFilePickerConstraints constraints;

  @override
  State<_SftpSelectionHost> createState() => _SftpSelectionHostState();
}

class _SftpSelectionHostState extends State<_SftpSelectionHost> {
  Object? _result = _pendingResult;
  bool _pickerOpen = true;

  @override
  Widget build(BuildContext context) => Navigator(
    pages: [
      MaterialPage<void>(
        key: const ValueKey<String>('selection-base'),
        child: Scaffold(
          body: Center(
            child: Text(switch (_result) {
              _PendingSelectionResult() => 'pending',
              null => 'cancelled',
              final List<RemoteFileSelection> files =>
                files.map((file) => file.remotePath).join('|'),
              final Object other => other.toString(),
            }),
          ),
        ),
      ),
      if (_pickerOpen)
        MaterialPage<void>(
          key: const ValueKey<String>('selection-picker'),
          child: SftpScreen(
            hostId: widget.hostId,
            connectionId: widget.connectionId,
            selectionConstraints: widget.constraints,
            showCloseButton: true,
          ),
        ),
    ],
    // ignore: deprecated_member_use
    onPopPage: (route, result) {
      if (!route.didPop(result)) {
        return false;
      }
      setState(() {
        _pickerOpen = false;
        _result = result;
      });
      return true;
    },
  );
}

class _PublicSftpSelectionHost extends StatefulWidget {
  const _PublicSftpSelectionHost({
    required this.hostId,
    required this.connectionId,
    required this.startDirectory,
  });

  final int hostId;
  final int connectionId;
  final String startDirectory;

  @override
  State<_PublicSftpSelectionHost> createState() =>
      _PublicSftpSelectionHostState();
}

class _PublicSftpSelectionHostState extends State<_PublicSftpSelectionHost> {
  List<RemoteFileSelection>? _result;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        const TextField(key: ValueKey('picker-source-field'), autofocus: true),
        FilledButton(
          onPressed: () async {
            final result = await showRemoteFilePicker(
              context: context,
              hostId: widget.hostId,
              connectionId: widget.connectionId,
              startDirectory: widget.startDirectory,
              constraints: const RemoteFilePickerConstraints(
                allowMultiple: true,
              ),
            );
            if (mounted) {
              setState(() => _result = result);
            }
          },
          child: const Text('Open remote picker'),
        ),
        Text(
          _result?.map((file) => file.remotePath).join('|') ?? 'no selection',
        ),
      ],
    ),
  );
}

class _PendingSelectionResult {
  const _PendingSelectionResult();
}

const _pendingResult = _PendingSelectionResult();

void main() {
  group('SFTP path helpers', () {
    test('parentRemotePath resolves POSIX parents', () {
      expect(parentRemotePath('/tmp/monkeyssh'), '/tmp');
      expect(parentRemotePath('/tmp'), '/');
      expect(parentRemotePath('/'), '/');
    });

    test('parentRemotePath resolves Windows drive parents', () {
      expect(parentRemotePath('C:/Users/demo'), 'C:/Users');
      expect(parentRemotePath('C:/Users'), 'C:/');
      expect(parentRemotePath('C:/'), 'C:/');
      expect(parentRemotePath('/C:/Users/demo'), '/C:/Users');
      expect(parentRemotePath('/C:/Users'), '/C:/');
      expect(parentRemotePath('/C:/'), '/C:/');
    });

    test('breadcrumbs preserve Windows drive roots', () {
      expect(buildSftpBreadcrumbItems('C:/Users/demo'), [
        (path: 'C:/', label: 'C:/'),
        (path: 'C:/Users', label: 'Users'),
        (path: 'C:/Users/demo', label: 'demo'),
      ]);
      expect(buildSftpBreadcrumbItems('/C:/Users/demo'), [
        (path: '/C:/', label: '/C:/'),
        (path: '/C:/Users', label: 'Users'),
        (path: '/C:/Users/demo', label: 'demo'),
      ]);
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

    test('requested files target their parent directory and file row', () {
      expect(
        resolveRequestedSftpNavigationTarget(
          '/var/log/app.log',
          isDirectory: false,
        ),
        (directoryPath: '/var/log', highlightedFileName: 'app.log'),
      );
    });

    test('location shortcuts normalize and de-duplicate paths', () {
      expect(
        resolveSftpLocationShortcuts(
          homeDirectory: '/home/depoll',
          connectionStartDirectory: '/home/depoll/./',
          tmuxPaneDirectory: '/home/depoll/project',
        ),
        ['/home/depoll', '/home/depoll/project'],
      );
    });

    test('location shortcuts keep Windows home directories', () {
      expect(
        resolveSftpLocationShortcuts(
          homeDirectory: r'C:\Users\depoll',
          connectionStartDirectory: 'C:/Users/depoll/./',
          tmuxPaneDirectory: 'C:/Users/depoll/project',
        ),
        ['C:/Users/depoll', 'C:/Users/depoll/project'],
      );
    });

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

    test('infers MIME types from previewable remote file names', () {
      expect(inferRemoteFileMimeType('diagram.svg'), 'image/svg+xml');
      expect(inferRemoteFileMimeType('photo.JPG'), 'image/jpeg');
      expect(inferRemoteFileMimeType('clip.webm'), 'video/webm');
      expect(inferRemoteFileMimeType('notes.txt'), isNull);
    });

    test('toggles remote file selection while preserving selection order', () {
      const alpha = RemoteFileSelection(
        remotePath: '/home/demo/alpha.txt',
        displayName: 'alpha.txt',
      );
      const beta = RemoteFileSelection(
        remotePath: '/home/demo/beta.txt',
        displayName: 'beta.txt',
      );

      expect(
        toggleRemoteFileSelection(
          currentSelection: const [alpha],
          file: beta,
          allowMultiple: true,
        ),
        const [alpha, beta],
      );
      expect(
        toggleRemoteFileSelection(
          currentSelection: const [alpha, beta],
          file: alpha,
          allowMultiple: true,
        ),
        const [beta],
      );
      expect(
        toggleRemoteFileSelection(
          currentSelection: const [alpha],
          file: beta,
          allowMultiple: false,
        ),
        const [beta],
      );
      expect(
        toggleRemoteFileSelection(
          currentSelection: const [beta],
          file: beta,
          allowMultiple: false,
        ),
        isEmpty,
      );
    });

    test(
      'describes disabled remote file selections from filters and limits',
      () {
        const alpha = RemoteFileSelection(
          remotePath: '/home/demo/alpha.txt',
          displayName: 'alpha.txt',
        );
        const beta = RemoteFileSelection(
          remotePath: '/home/demo/beta.txt',
          displayName: 'beta.txt',
        );
        const blocked = RemoteFileSelection(
          remotePath: '/home/demo/blocked.png',
          displayName: 'blocked.png',
        );
        final constraints = RemoteFilePickerConstraints(
          allowMultiple: true,
          maxSelectionCount: 1,
          selectionAvailability: (file) => file.displayName.endsWith('.png')
              ? 'Only text attachments are supported.'
              : null,
        );

        expect(
          resolveRemoteFileSelectionDisabledReason(
            constraints: constraints,
            currentSelection: const [alpha],
            candidate: beta,
          ),
          'You can select up to 1 file.',
        );
        expect(
          resolveRemoteFileSelectionDisabledReason(
            constraints: constraints,
            currentSelection: const [alpha],
            candidate: blocked,
          ),
          'Only text attachments are supported.',
        );
      },
    );

    test('builds selection semantics labels, hints, and touch tooltips', () {
      expect(
        remoteFileSelectionSemanticsLabel(
          isDirectory: true,
          fileName: 'docs',
          isSelected: false,
        ),
        'Open folder docs',
      );
      expect(
        remoteFileSelectionSemanticsHint(isDirectory: true, isSelected: false),
        'Opens this folder.',
      );
      expect(
        remoteFileSelectionSemanticsLabel(
          isDirectory: false,
          fileName: 'notes.txt',
          isSelected: false,
        ),
        'Select remote file notes.txt',
      );
      expect(
        remoteFileSelectionSemanticsHint(isDirectory: false, isSelected: true),
        'Removes this file from the current selection.',
      );
      expect(
        remoteFileSelectionTooltip(
          isDirectory: false,
          fileName: 'notes.txt',
          isSelected: true,
        ),
        'Deselect notes.txt',
      );
      expect(
        remoteFileSelectionTooltip(
          isDirectory: false,
          fileName: 'blocked.png',
          isSelected: false,
          disabledReason: 'Only text attachments are supported.',
        ),
        'blocked.png is unavailable: Only text attachments are supported.',
      );
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
    });

    test(
      'opens an upload stream from the picked file path when needed',
      () async {
        final tempDirectory = Directory('build/sftp-upload-test')
          ..createSync(recursive: true);
        addTearDown(() => tempDirectory.delete(recursive: true));

        final fileOnDisk = File('${tempDirectory.path}/notes.txt');
        await fileOnDisk.writeAsString('copilot');

        final file = AppPlatformFile(
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
          AppPlatformFile(name: 'notes.txt', size: 0),
        ]),
        'Unable to read "notes.txt"',
      );
    });

    test('uses a pluralized count when multiple uploads are unreadable', () {
      expect(
        resolveUnreadableSftpUploadMessage([
          AppPlatformFile(name: 'notes.txt', size: 0),
          AppPlatformFile(name: 'todo.txt', size: 0),
        ]),
        'Unable to read 2 selected files',
      );
    });

    test('rejects picker names that can escape the upload directory', () {
      expect(validateSftpUploadFileName('notes.txt'), isNull);
      expect(validateSftpUploadFileName('..'), isNotNull);
      expect(validateSftpUploadFileName('../authorized_keys'), isNotNull);
      expect(validateSftpUploadFileName(r'..\authorized_keys'), isNotNull);
      expect(validateSftpUploadFileName('/tmp/payload'), isNotNull);
      expect(validateSftpUploadFileName('bad\x00name'), isNotNull);
    });

    test('does not echo unsafe upload names in validation feedback', () {
      expect(
        resolveUnsafeSftpUploadNameMessage([
          AppPlatformFile(name: '../authorized_keys', size: 0),
        ]),
        'The selected file has an unsafe name',
      );
      expect(
        resolveUnsafeSftpUploadNameMessage([
          AppPlatformFile(name: '../one', size: 0),
          AppPlatformFile(name: r'..\two', size: 0),
        ]),
        '2 selected files have unsafe names',
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
      expect(
        find.text('/home/depoll/screen-recording.mp4'),
        findsAtLeastNWidgets(1),
      );
      expect(find.text('42 B'), findsOneWidget);
      expect(find.text('video/mp4'), findsOneWidget);
      expect(find.text('Cached copy'), findsOneWidget);
      expect(find.text('Save copy'), findsOneWidget);
      expect(find.text('Open/Share'), findsOneWidget);
    });

    testWidgets(
      'requested image files open directly and return to a highlighted row',
      (tester) async {
        final sshClient = _MockSshClient();
        final sftp = _MockSftpClient();
        final remoteFile = _MockSftpFile();
        final monetizationService = _MockMonetizationService();
        final session = SshSession(
          connectionId: 7,
          hostId: 1,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'demo.example.com',
            port: 22,
            username: 'demo',
          ),
        );

        when(
          () => monetizationService.currentState,
        ).thenReturn(_proMonetizationState);
        when(sshClient.sftp).thenAnswer((_) async => sftp);
        when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
        when(() => sftp.stat('/home/demo/picture.png')).thenAnswer(
          (_) async => SftpFileAttrs(
            size: _onePixelPngBytes.length,
            mode: const SftpFileMode.value(1 << 15),
          ),
        );
        when(() => sftp.listdir('/home/demo')).thenAnswer(
          (_) async => [
            SftpName(
              filename: 'picture.png',
              longname: 'picture.png',
              attr: SftpFileAttrs(
                size: _onePixelPngBytes.length,
                mode: const SftpFileMode.value(1 << 15),
              ),
            ),
          ],
        );
        when(
          () => sftp.open('/home/demo/picture.png'),
        ).thenAnswer((_) async => remoteFile);
        when(
          () => remoteFile.readBytes(length: any(named: 'length')),
        ).thenAnswer((_) async => _onePixelPngBytes);
        when(remoteFile.close).thenAnswer((_) async {});

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeSessionsProvider.overrideWith(
                () => _TestActiveSessionsNotifier(session),
              ),
              monetizationServiceProvider.overrideWithValue(
                monetizationService,
              ),
              monetizationStateProvider.overrideWith(
                (ref) => Stream.value(_proMonetizationState),
              ),
            ],
            child: const MaterialApp(
              home: SftpScreen(
                hostId: 1,
                connectionId: 7,
                initialPath: '/home/demo/picture.png',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('/home/demo/picture.png'), findsOneWidget);

        Navigator.of(tester.element(find.text('/home/demo/picture.png'))).pop();
        await tester.pumpAndSettle();

        final tile = tester.widget<ListTile>(
          find.ancestor(
            of: find.text('picture.png'),
            matching: find.byType(ListTile),
          ),
        );
        expect(tile.tileColor, isNotNull);
        verify(() => sftp.open('/home/demo/picture.png')).called(1);
      },
    );

    testWidgets('cancelling remote file picker returns null', (tester) async {
      final sshClient = _MockSshClient();
      final sftp = _MockSftpClient();
      final monetizationService = _MockMonetizationService();
      final session = SshSession(
        connectionId: 7,
        hostId: 1,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'demo.example.com',
          port: 22,
          username: 'demo',
        ),
      );
      addTearDown(session.close);

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(sshClient.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
      when(
        () => sftp.listdir('/home/demo'),
      ).thenAnswer((_) async => [_fileEntry('notes.txt', size: 7)]);

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          monetizationService: monetizationService,
          child: const _SftpSelectionHost(
            hostId: 1,
            connectionId: 7,
            constraints: RemoteFilePickerConstraints(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('cancelled'), findsOneWidget);
    });

    testWidgets(
      'public remote picker dismisses input, lists workspace files, and returns selection',
      (tester) async {
        final sshClient = _MockSshClient();
        final sftp = _MockSftpClient();
        final monetizationService = _MockMonetizationService();
        final session = SshSession(
          connectionId: 7,
          hostId: 1,
          client: sshClient,
          config: const SshConnectionConfig(
            hostname: 'demo.example.com',
            port: 22,
            username: 'demo',
          ),
        );
        addTearDown(session.close);

        when(
          () => monetizationService.currentState,
        ).thenReturn(_proMonetizationState);
        when(sshClient.sftp).thenAnswer((_) async => sftp);
        when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
        when(() => sftp.stat('/repo')).thenAnswer(
          (_) async => SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
        );
        when(
          () => sftp.listdir('/repo'),
        ).thenAnswer((_) async => [_fileEntry('notes.txt', size: 7)]);

        await tester.pumpWidget(
          _buildSftpTestApp(
            session: session,
            monetizationService: monetizationService,
            child: const _PublicSftpSelectionHost(
              hostId: 1,
              connectionId: 7,
              startDirectory: '/repo',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.testTextInput.isVisible, isTrue);

        await tester.tap(find.text('Open remote picker'));
        await tester.pump();
        await tester.pumpAndSettle();

        expect(tester.testTextInput.isVisible, isFalse);
        expect(find.textContaining('Select files'), findsOneWidget);
        verify(() => sftp.listdir('/repo')).called(1);
        expect(find.text('notes.txt'), findsOneWidget);
        await tester.tap(find.text('notes.txt'));
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Select 1 file'));
        await tester.pumpAndSettle();

        expect(find.text('/repo/notes.txt'), findsOneWidget);
      },
    );

    testWidgets('normal mode still previews tapped image files', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final sftp = _MockSftpClient();
      final remoteFile = _MockSftpFile();
      final monetizationService = _MockMonetizationService();
      final session = SshSession(
        connectionId: 7,
        hostId: 1,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'demo.example.com',
          port: 22,
          username: 'demo',
        ),
      );
      addTearDown(session.close);

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(sshClient.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
      when(() => sftp.listdir('/home/demo')).thenAnswer(
        (_) async => [
          _fileEntry('picture.png', size: _onePixelPngBytes.length),
        ],
      );
      when(
        () => sftp.open('/home/demo/picture.png'),
      ).thenAnswer((_) async => remoteFile);
      when(
        () => remoteFile.readBytes(length: any(named: 'length')),
      ).thenAnswer((_) async => _onePixelPngBytes);
      when(remoteFile.close).thenAnswer((_) async {});

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          monetizationService: monetizationService,
          child: const SftpScreen(hostId: 1, connectionId: 7),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('picture.png'));
      await tester.pumpAndSettle();

      expect(find.text('/home/demo/picture.png'), findsOneWidget);
      verify(() => sftp.open('/home/demo/picture.png')).called(1);
    });

    testWidgets('normal mode shows 0 B for files with unknown size', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final sftp = _MockSftpClient();
      final monetizationService = _MockMonetizationService();
      final session = SshSession(
        connectionId: 7,
        hostId: 1,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'demo.example.com',
          port: 22,
          username: 'demo',
        ),
      );
      addTearDown(session.close);

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(sshClient.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('.')).thenAnswer((_) async => '/home/demo');
      when(
        () => sftp.listdir('/home/demo'),
      ).thenAnswer((_) async => [_fileEntry('notes.txt')]);

      await tester.pumpWidget(
        _buildSftpTestApp(
          session: session,
          monetizationService: monetizationService,
          child: const SftpScreen(hostId: 1, connectionId: 7),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.text('0 B'), findsOneWidget);
    });

    testWidgets('handles stale SSH errors while opening the browser', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final monetizationService = _MockMonetizationService();
      final session = SshSession(
        connectionId: 7,
        hostId: 1,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'demo.example.com',
          port: 22,
          username: 'demo',
        ),
      );

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(sshClient.sftp).thenThrow(SSHStateError('Transport is closed'));
      addTearDown(session.close);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeSessionsProvider.overrideWith(
              () => _TestActiveSessionsNotifier(session),
            ),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),
          ],
          child: const MaterialApp(
            home: SftpScreen(hostId: 1, connectionId: 7),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'SFTP connection failed. Check the connection and try again.',
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final replacementReady in [false, true]) {
      for (final oldOutcome in ['client', 'error', 'timeout']) {
        testWidgets('failed SFTP browser waiter preserves '
            '${replacementReady ? 'cached' : 'pending'} replacement '
            'after late $oldOutcome and Retry', (tester) async {
          final sshClient = _MockSshClient();
          final oldClient = _MockSftpClient();
          final replacement = _MockSftpClient();
          final oldOpen = Completer<SftpClient>();
          final newOpen = Completer<SftpClient>();
          final monetizationService = _MockMonetizationService();
          final session = SshSession(
            connectionId: 7,
            hostId: 1,
            client: sshClient,
            config: const SshConnectionConfig(
              hostname: 'demo.example.com',
              port: 22,
              username: 'demo',
            ),
          );
          addTearDown(session.close);
          when(
            () => monetizationService.currentState,
          ).thenReturn(_proMonetizationState);
          var opens = 0;
          when(
            sshClient.sftp,
          ).thenAnswer((_) => opens++ == 0 ? oldOpen.future : newOpen.future);
          when(
            () => replacement.absolute('.'),
          ).thenAnswer((_) async => '/home/demo');
          when(
            () => replacement.listdir('/home/demo'),
          ).thenAnswer((_) async => [_fileEntry('replacement.txt')]);

          // The browser joins another consumer's shared pending open.
          final oldFuture = session.sftp();
          await tester.pumpWidget(
            _buildSftpTestApp(
              session: session,
              monetizationService: monetizationService,
              child: const SftpScreen(hostId: 1, connectionId: 7),
            ),
          );
          await tester.pump();
          expect(opens, 1);

          // That consumer times out and starts a replacement while the
          // browser still awaits the old open.
          session.discardSftpOpen(oldFuture);
          final next = session.sftp();
          if (replacementReady) {
            newOpen.complete(replacement);
            await tester.pump();
            expect(await next, same(replacement));
          }

          if (oldOutcome == 'timeout') {
            await tester.pump(const Duration(seconds: 11));
          } else if (oldOutcome == 'error') {
            oldOpen.completeError(SSHStateError('Old channel failed'));
          } else {
            oldOpen.complete(oldClient);
          }
          await tester.pumpAndSettle();

          // Exercise _handleConnectFailure, including its null-client
          // cleanup, rather than stopping at the service's rejected future.
          expect(
            find.text(
              oldOutcome == 'timeout'
                  ? sftpTimeoutMessage('opening the SFTP browser')
                  : 'SFTP connection failed. Check the connection and try again.',
            ),
            findsOneWidget,
          );
          if (!replacementReady) {
            expect(session.sftp(), same(next));
            newOpen.complete(replacement);
            await tester.pump();
          }
          expect(await next, same(replacement));
          if (oldOutcome == 'timeout') {
            oldOpen.complete(oldClient);
            await tester.pump();
          }
          expect(await session.sftp(), same(replacement));
          verifyNever(replacement.close);
          if (oldOutcome != 'error') {
            verify(oldClient.close).called(1);
          }

          await tester.tap(find.text('Retry'));
          await tester.pumpAndSettle();
          expect(find.text('replacement.txt'), findsOneWidget);
          expect(opens, 2);
          verifyNever(replacement.close);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }

    testWidgets('reopens SFTP when the directory channel goes stale', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final staleSftp = _MockSftpClient();
      final freshSftp = _MockSftpClient();
      final monetizationService = _MockMonetizationService();
      final session = SshSession(
        connectionId: 7,
        hostId: 1,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'demo.example.com',
          port: 22,
          username: 'demo',
        ),
      );
      var sftpOpenAttempts = 0;

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(sshClient.sftp).thenAnswer((_) async {
        sftpOpenAttempts++;
        return sftpOpenAttempts == 1 ? staleSftp : freshSftp;
      });
      when(() => staleSftp.absolute('.')).thenAnswer((_) async => '/home/demo');
      when(
        () => staleSftp.listdir('/home/demo'),
      ).thenThrow(SSHStateError('Connection closed'));
      when(staleSftp.close).thenAnswer((_) async {});
      when(() => freshSftp.listdir('/home/demo')).thenAnswer(
        (_) async => [
          SftpName(
            filename: 'notes.txt',
            longname: 'notes.txt',
            attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 15)),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeSessionsProvider.overrideWith(
              () => _TestActiveSessionsNotifier(session),
            ),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),
          ],
          child: const MaterialApp(
            home: SftpScreen(hostId: 1, connectionId: 7),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('notes.txt'), findsOneWidget);
      expect(sftpOpenAttempts, 2);
      verify(staleSftp.close).called(1);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('opens a Windows remote home directory from SFTP realpath', (
      tester,
    ) async {
      final sshClient = _MockSshClient();
      final sftp = _MockSftpClient();
      final monetizationService = _MockMonetizationService();
      final session = SshSession(
        connectionId: 7,
        hostId: 1,
        client: sshClient,
        config: const SshConnectionConfig(
          hostname: 'windows.example.com',
          port: 22,
          username: 'demo',
        ),
      );

      when(
        () => monetizationService.currentState,
      ).thenReturn(_proMonetizationState);
      when(sshClient.sftp).thenAnswer((_) async => sftp);
      when(() => sftp.absolute('.')).thenAnswer((_) async => r'C:\Users\demo');
      when(() => sftp.listdir('C:/Users/demo')).thenAnswer(
        (_) async => [
          SftpName(
            filename: 'Documents',
            longname: 'Documents',
            attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 14)),
          ),
          SftpName(
            filename: 'notes.txt',
            longname: 'notes.txt',
            attr: SftpFileAttrs(mode: const SftpFileMode.value(1 << 15)),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeSessionsProvider.overrideWith(
              () => _TestActiveSessionsNotifier(session),
            ),
            monetizationServiceProvider.overrideWithValue(monetizationService),
            monetizationStateProvider.overrideWith(
              (ref) => Stream.value(_proMonetizationState),
            ),
          ],
          child: const MaterialApp(
            home: SftpScreen(hostId: 1, connectionId: 7),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('C:/'), findsOneWidget);
      expect(find.text('Users'), findsOneWidget);
      expect(find.text('demo'), findsOneWidget);
      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('notes.txt'), findsOneWidget);
      verify(() => sftp.listdir('C:/Users/demo')).called(1);

      await tester.pumpWidget(const SizedBox.shrink());
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
