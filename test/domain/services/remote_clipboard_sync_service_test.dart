import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/remote_clipboard_sync_service.dart';

void main() {
  group('RemoteClipboardSyncService', () {
    final hasPosixShell = File('/bin/sh').existsSync();

    test('canSyncText rejects oversized content', () {
      final text = 'a' * (1024 * 1024 + 1);
      expect(RemoteClipboardSyncService.canSyncText(text), isFalse);
    });

    test('buildReadCommand probes common clipboard utilities', () {
      final command = RemoteClipboardSyncService.buildReadCommand();
      expect(command, contains('pbpaste'));
      expect(command, contains('reattach-to-user-namespace'));
      expect(command, contains('launchctl'));
      expect(command, contains('wl-paste'));
      expect(command, contains('xclip'));
      expect(command, contains('xsel'));
      expect(command, contains(RemoteClipboardSyncService.failureMarker));
    });

    test('buildWriteCommand probes common clipboard utilities', () {
      final command = RemoteClipboardSyncService.buildWriteCommand('hello');
      expect(command, contains('pbcopy'));
      expect(command, contains('reattach-to-user-namespace'));
      expect(command, contains('launchctl'));
      expect(command, contains('wl-copy'));
      expect(command, contains('xclip -selection clipboard'));
      expect(command, contains('xsel --clipboard --input'));
      expect(command, contains(RemoteClipboardSyncService.failureMarker));
    });

    test('parseReadOutput decodes clipboard payload', () {
      final result = RemoteClipboardSyncService.parseReadOutput('aGVsbG8=');
      expect(result.status, RemoteClipboardReadStatus.supported);
      expect(result.text, 'hello');
    });

    test('parseReadOutput treats empty output as an empty clipboard', () {
      final result = RemoteClipboardSyncService.parseReadOutput('');
      expect(result.status, RemoteClipboardReadStatus.supported);
      expect(result.text, isEmpty);
    });

    test('parseReadOutput detects unsupported clipboard', () {
      final result = RemoteClipboardSyncService.parseReadOutput(
        RemoteClipboardSyncService.unsupportedMarker,
      );
      expect(result.status, RemoteClipboardReadStatus.unsupported);
      expect(result.text, isEmpty);
    });

    test('parseReadOutput detects failed clipboard utility', () {
      final result = RemoteClipboardSyncService.parseReadOutput(
        RemoteClipboardSyncService.failureMarker,
      );
      expect(result.status, RemoteClipboardReadStatus.failed);
      expect(result.text, isEmpty);
    });

    test('parseReadOutput treats invalid payload as failed', () {
      final result = RemoteClipboardSyncService.parseReadOutput('not-base64');
      expect(result.status, RemoteClipboardReadStatus.failed);
      expect(result.text, isEmpty);
    });

    test('output helpers detect status markers', () {
      expect(
        RemoteClipboardSyncService.outputIndicatesUnsupported(
          RemoteClipboardSyncService.unsupportedMarker,
        ),
        isTrue,
      );
      expect(
        RemoteClipboardSyncService.outputIndicatesFailure(
          RemoteClipboardSyncService.failureMarker,
        ),
        isTrue,
      );
    });

    test('read command emits encoded output from pbpaste', () async {
      final bin = await _createClipboardBin({
        'pbpaste': '#!/bin/sh\nprintf stub-read\n',
      });
      addTearDown(() => bin.delete(recursive: true));

      final result = await _runClipboardCommand(
        RemoteClipboardSyncService.buildReadCommand(),
        bin,
      );

      expect(result.exitCode, 0);
      expect(result.stdout, base64Encode(utf8.encode('stub-read')));
    }, skip: !hasPosixShell);

    test('read command emits failure marker when pbpaste fails', () async {
      final bin = await _createClipboardBin({'pbpaste': '#!/bin/sh\nexit 1\n'});
      addTearDown(() => bin.delete(recursive: true));

      final result = await _runClipboardCommand(
        RemoteClipboardSyncService.buildReadCommand(),
        bin,
      );

      expect(result.exitCode, 0);
      expect(result.stdout, RemoteClipboardSyncService.failureMarker);
    }, skip: !hasPosixShell);

    test('write command sends decoded payload to pbcopy', () async {
      final bin = await _createClipboardBin({});
      addTearDown(() => bin.delete(recursive: true));
      final written = File('${bin.path}/written');
      await _writeExecutable(
        File('${bin.path}/pbcopy'),
        '#!/bin/sh\ncat > ${_shellQuote(written.path)}\n',
      );

      final result = await _runClipboardCommand(
        RemoteClipboardSyncService.buildWriteCommand('hello'),
        bin,
      );

      expect(result.exitCode, 0);
      expect(result.stdout, isEmpty);
      expect(await written.readAsString(), 'hello');
    }, skip: !hasPosixShell);

    test('write command emits failure marker when pbcopy fails', () async {
      final bin = await _createClipboardBin({
        'pbcopy': '#!/bin/sh\ncat >/dev/null\nexit 1\n',
      });
      addTearDown(() => bin.delete(recursive: true));

      final result = await _runClipboardCommand(
        RemoteClipboardSyncService.buildWriteCommand('hello'),
        bin,
      );

      expect(result.exitCode, 0);
      expect(result.stdout, RemoteClipboardSyncService.failureMarker);
    }, skip: !hasPosixShell);
  });
}

Future<Directory> _createClipboardBin(Map<String, String> scripts) async {
  final directory = await Directory.systemTemp.createTemp('flutty_clipboard_');
  for (final entry in scripts.entries) {
    await _writeExecutable(File('${directory.path}/${entry.key}'), entry.value);
  }
  return directory;
}

Future<ProcessResult> _runClipboardCommand(String command, Directory bin) {
  final existingPath = Platform.environment['PATH'];
  final path = existingPath == null || existingPath.isEmpty
      ? bin.path
      : '${bin.path}:$existingPath';
  return Process.run('/bin/sh', ['-c', command], environment: {'PATH': path});
}

Future<void> _writeExecutable(File file, String contents) async {
  await file.writeAsString(contents);
  final chmod = await Process.run('chmod', ['+x', file.path]);
  if (chmod.exitCode != 0) {
    throw StateError('Failed to mark ${file.path} executable');
  }
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
