import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

/// Display path for files pasted directly into a terminal session.
const remoteClipboardUploadDirectoryDisplay = '~/.cache/monkeyssh/uploads';

/// Private directory permissions for terminal upload staging directories.
final remoteUploadDirectoryMode = SftpFileMode(
  groupRead: false,
  groupWrite: false,
  groupExecute: false,
  otherRead: false,
  otherWrite: false,
  otherExecute: false,
);

/// Private file permissions for terminal upload staging files.
final remoteUploadFileMode = SftpFileMode(
  userExecute: false,
  groupRead: false,
  groupWrite: false,
  groupExecute: false,
  otherRead: false,
  otherWrite: false,
  otherExecute: false,
);

/// Builds the remote directory for files pasted directly into a terminal.
String buildRemoteClipboardUploadDirectory(String homeDirectory) =>
    joinRemotePath(homeDirectory, '.cache/monkeyssh/uploads');

/// Builds the app-owned parent directory for terminal uploads.
String buildRemoteClipboardUploadParentDirectory(String homeDirectory) =>
    joinRemotePath(homeDirectory, '.cache/monkeyssh');

/// Joins a remote directory and child name into a normalized absolute path.
String joinRemotePath(String directory, String name) {
  final cleanName = name.replaceFirst(RegExp('^/+'), '');
  final baseDirectory = directory.isEmpty ? '/' : directory;
  final joined = path.posix.join(baseDirectory, cleanName);
  final normalized = path.posix.normalize(joined);
  return normalized.startsWith('/') ? normalized : '/$normalized';
}

/// Normalizes an absolute remote path by collapsing `.`, `..`, and extra `/`.
String? normalizeSftpAbsolutePath(String? path) {
  final trimmedPath = path?.trim();
  if (trimmedPath == null ||
      trimmedPath.isEmpty ||
      !trimmedPath.startsWith('/')) {
    return null;
  }

  final segments = <String>[];
  for (final segment in trimmedPath.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty) {
        segments.removeLast();
      }
      continue;
    }
    segments.add(segment);
  }

  return segments.isEmpty ? '/' : '/${segments.join('/')}';
}

/// Resolves a requested SFTP path against terminal context.
String? resolveRequestedSftpPath(
  String? requestedPath, {
  String? workingDirectory,
  String? homeDirectory,
}) {
  final trimmedPath = requestedPath?.trim();
  if (trimmedPath == null || trimmedPath.isEmpty) {
    return null;
  }

  if (trimmedPath.startsWith('/')) {
    return normalizeSftpAbsolutePath(trimmedPath);
  }

  if (trimmedPath == '~' || trimmedPath.startsWith('~/')) {
    final normalizedHomeDirectory = normalizeSftpAbsolutePath(homeDirectory);
    if (normalizedHomeDirectory == null) {
      return null;
    }
    if (trimmedPath == '~') {
      return normalizedHomeDirectory;
    }
    return normalizeSftpAbsolutePath(
      joinRemotePath(normalizedHomeDirectory, trimmedPath.substring(2)),
    );
  }

  final normalizedWorkingDirectory = normalizeSftpAbsolutePath(
    workingDirectory,
  );
  if (normalizedWorkingDirectory == null) {
    return null;
  }

  return normalizeSftpAbsolutePath(
    joinRemotePath(normalizedWorkingDirectory, trimmedPath),
  );
}

/// Sanitizes a filename for remote uploads.
///
/// Restricts the name to a strict shell-safe allowlist (letters, digits, `.`,
/// `_`, `-`) so the resulting remote path can be pasted into the terminal
/// unquoted. Unquoted paths are required for agent CLIs (e.g. Copilot CLI) to
/// recognise a pasted path as an attachment, and the allowlist keeps the file
/// extension intact so image previews still resolve.
String sanitizeRemoteUploadFileName(String name) {
  final sanitized = path
      .basename(name)
      .trim()
      .replaceAll(RegExp('[^A-Za-z0-9._-]'), '-')
      .replaceAll(RegExp('-+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return sanitized.isEmpty ? 'file' : sanitized;
}

/// Creates a unique remote filename for clipboard uploads.
String buildClipboardUploadFileName(
  String originalName,
  DateTime timestamp, {
  int sequence = 0,
}) {
  final safeName = sanitizeRemoteUploadFileName(originalName);
  return 'clipboard-${timestamp.toUtc().millisecondsSinceEpoch}-$sequence-$safeName';
}

/// Builds a remote filename for clipboard image uploads.
String buildClipboardImageFileName(DateTime timestamp, {int sequence = 0}) =>
    buildClipboardUploadFileName('image.png', timestamp, sequence: sequence);

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

/// Bracketed-paste introducer and terminator (`CSI 200~` / `CSI 201~`).
const _bracketedPasteStart = '\x1b[200~';
const _bracketedPasteEnd = '\x1b[201~';

/// Builds the terminal-input segments that reference uploaded [remotePaths]
/// after a paste upload.
///
/// When [bracketedPasteMode] is enabled, each path is returned as its own
/// bracketed-paste segment (`CSI 200~ <path> CSI 201~ ` with a trailing space).
/// The caller must write these segments sequentially with a short delay between
/// them: an agent CLI such as Copilot CLI only recognises each path as a
/// separate attachment — rendering a preview chip per file — when the bracketed
/// pastes arrive as distinct reads. The trailing space also keeps the paths
/// usable as distinct shell arguments.
///
/// When [bracketedPasteMode] is disabled, all paths are returned as a single
/// space-separated segment (a plain prompt shows no preview either way).
///
/// Uploaded remote paths come from [sanitizeRemoteUploadFileName] inside a fixed
/// cache directory, so they contain no shell metacharacters and need no
/// quoting. Segments must be written straight to the session input sink (e.g.
/// `Terminal.onOutput`), not through `Terminal.paste`, which would strip the
/// bracketed-paste control sequences.
List<String> buildTerminalAttachmentPasteSegments(
  Iterable<String> remotePaths, {
  required bool bracketedPasteMode,
}) {
  final paths = remotePaths
      .where((remotePath) => remotePath.isNotEmpty)
      .toList();
  if (paths.isEmpty) {
    return const [];
  }
  if (!bracketedPasteMode) {
    return ['${paths.join(' ')} '];
  }
  return [
    for (final remotePath in paths)
      '$_bracketedPasteStart$remotePath$_bracketedPasteEnd ',
  ];
}

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
  Future<void> ensureDirectoryExists(
    SftpClient sftp,
    String remotePath, {
    SftpFileMode? mode,
  }) async {
    try {
      final stat = await sftp.stat(remotePath);
      if (!stat.isDirectory) {
        throw FileSystemException(
          'Remote path exists but is not a directory',
          remotePath,
        );
      }
      if (mode != null) {
        await sftp.setStat(remotePath, SftpFileAttrs(mode: mode));
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
    try {
      await sftp.mkdir(
        remotePath,
        mode == null ? null : SftpFileAttrs(mode: mode),
      );
      if (mode != null) {
        await sftp.setStat(remotePath, SftpFileAttrs(mode: mode));
      }
    } on SftpStatusError catch (error, stackTrace) {
      try {
        final stat = await sftp.stat(remotePath);
        if (stat.isDirectory) {
          if (mode != null) {
            await sftp.setStat(remotePath, SftpFileAttrs(mode: mode));
          }
          return;
        }
      } on SftpStatusError {
        Error.throwWithStackTrace(error, stackTrace);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
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
    await sftp.setStat(remotePath, SftpFileAttrs(mode: remoteUploadFileMode));
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
