import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

/// Default remote directory for files pasted directly into a terminal session.
const remoteClipboardUploadDirectory = '/tmp/monkeyssh';

/// Joins a remote directory and child name into a normalized absolute path.
String joinRemotePath(String directory, String name) {
  if (directory == '/') {
    return '/$name';
  }
  return '$directory/$name';
}

/// Sanitizes a filename for remote uploads.
String sanitizeRemoteUploadFileName(String name) {
  final sanitized = path
      .basename(name)
      .trim()
      .replaceAll(RegExp(r'[\\/\x00-\x1F]'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp('-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return sanitized.isEmpty ? 'file' : sanitized;
}

/// Creates a unique remote filename for clipboard uploads.
String buildClipboardUploadFileName(String originalName, DateTime timestamp) {
  final safeName = sanitizeRemoteUploadFileName(originalName);
  return 'clipboard-${timestamp.toUtc().millisecondsSinceEpoch}-$safeName';
}

/// Builds a remote filename for clipboard image uploads.
String buildClipboardImageFileName(DateTime timestamp) =>
    buildClipboardUploadFileName('image.png', timestamp);

/// Formats a byte count into a human-readable file size.
String formatRemoteFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Whether the byte sample looks like binary content.
bool looksLikeBinaryContent(Uint8List bytes) {
  final sample = bytes.length > 1024 ? bytes.sublist(0, 1024) : bytes;
  return sample.contains(0);
}

/// Escapes a path so it can be pasted directly into a POSIX shell.
String shellEscapePosix(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// Builds the shell text inserted into the terminal after file uploads.
String buildTerminalUploadInsertion(Iterable<String> remotePaths) =>
    remotePaths.map(shellEscapePosix).join(' ');

/// Shared helpers for remote file transfers over SFTP.
final remoteFileServiceProvider = Provider<RemoteFileService>(
  (ref) => const RemoteFileService(),
);

/// Shared helpers for remote file transfers over SFTP.
class RemoteFileService {
  /// Creates a new [RemoteFileService].
  const RemoteFileService();

  /// Resolves the remote home directory for an SFTP session.
  Future<String> resolveInitialDirectory(SftpClient sftp) => sftp.absolute('.');

  /// Ensures the target remote directory exists.
  Future<void> ensureDirectoryExists(SftpClient sftp, String remotePath) async {
    try {
      final stat = await sftp.stat(remotePath);
      if (!stat.isDirectory) {
        throw FileSystemException(
          'Remote path exists but is not a directory',
          remotePath,
        );
      }
      return;
    } on SftpStatusError catch (error) {
      if (error.code != SftpStatusCode.noSuchFile) {
        rethrow;
      }
    }

    final parentPath = path.posix.dirname(remotePath);
    if (parentPath != remotePath) {
      await ensureDirectoryExists(sftp, parentPath);
    }
    await sftp.mkdir(remotePath);
  }

  /// Downloads a remote file to a local path.
  Future<void> downloadFile({
    required SftpClient sftp,
    required String remotePath,
    required String localPath,
  }) async {
    final remoteFile = await sftp.open(remotePath);
    final sink = File(localPath).openWrite();
    try {
      await for (final chunk in remoteFile.read()) {
        sink.add(chunk);
      }
    } finally {
      await sink.close();
      await remoteFile.close();
    }
  }

  /// Uploads a stream into a remote file path.
  Future<void> uploadStream({
    required SftpClient sftp,
    required String remotePath,
    required Stream<List<int>> stream,
  }) async {
    final remoteFile = await sftp.open(
      remotePath,
      mode:
          SftpFileOpenMode.write |
          SftpFileOpenMode.create |
          SftpFileOpenMode.truncate,
    );
    try {
      await remoteFile.write(_normalizeByteStream(stream)).done;
    } finally {
      await remoteFile.close();
    }
  }

  /// Uploads raw bytes into a remote file path.
  Future<void> uploadBytes({
    required SftpClient sftp,
    required String remotePath,
    required Uint8List bytes,
  }) => uploadStream(
    sftp: sftp,
    remotePath: remotePath,
    stream: Stream<List<int>>.value(bytes),
  );

  Stream<Uint8List> _normalizeByteStream(Stream<List<int>> stream) => stream
      .map((chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
}
