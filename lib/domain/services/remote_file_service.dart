import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

final _sftpWindowsDriveRootPattern = RegExp(r'^/?[A-Za-z]:(?:/|$)');

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

String _normalizeSftpPathSeparators(String value) =>
    value.replaceAll(r'\', '/');

({String root, String rest})? _splitSftpWindowsDriveRoot(String remotePath) {
  final match = _sftpWindowsDriveRootPattern.matchAsPrefix(remotePath);
  if (match == null) {
    return null;
  }

  final matchedRoot = remotePath.substring(0, match.end);
  final root = matchedRoot.endsWith('/') ? matchedRoot : '$matchedRoot/';
  return (root: root, rest: remotePath.substring(match.end));
}

List<String> _normalizeSftpPathSegments(String pathSuffix) {
  final segments = <String>[];
  for (final segment in pathSuffix.split('/')) {
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
  return segments;
}

/// Whether [remotePath] is an absolute SFTP path.
bool isSftpAbsolutePath(String remotePath) =>
    normalizeSftpAbsolutePath(remotePath) != null;

/// Returns the root segment for an absolute SFTP path.
String? sftpPathRoot(String remotePath) {
  final normalizedPath = normalizeSftpAbsolutePath(remotePath);
  if (normalizedPath == null) {
    return null;
  }
  if (normalizedPath == '/') {
    return '/';
  }
  return _splitSftpWindowsDriveRoot(normalizedPath)?.root;
}

/// Whether [remotePath] is the root of an SFTP path hierarchy.
bool isSftpPathRoot(String remotePath) {
  final normalizedPath = normalizeSftpAbsolutePath(remotePath);
  if (normalizedPath == null) {
    return false;
  }
  return normalizedPath == sftpPathRoot(normalizedPath);
}

/// Returns the parent directory for an absolute SFTP path.
String parentSftpPath(String remotePath) {
  final normalizedPath = normalizeSftpAbsolutePath(remotePath);
  if (normalizedPath == null) {
    final parent = path.posix.dirname(_normalizeSftpPathSeparators(remotePath));
    return parent.isEmpty || parent == '.' ? '/' : parent;
  }
  if (normalizedPath == '/') {
    return '/';
  }

  final windowsRoot = _splitSftpWindowsDriveRoot(normalizedPath);
  if (windowsRoot != null) {
    if (normalizedPath == windowsRoot.root) {
      return windowsRoot.root;
    }
    final trimmedPath = normalizedPath.endsWith('/')
        ? normalizedPath.substring(0, normalizedPath.length - 1)
        : normalizedPath;
    final slashIndex = trimmedPath.lastIndexOf('/');
    if (slashIndex < windowsRoot.root.length) {
      return windowsRoot.root;
    }
    return trimmedPath.substring(0, slashIndex);
  }

  final parent = path.posix.dirname(normalizedPath);
  return parent.isEmpty || parent == '.' ? '/' : parent;
}

/// Joins a remote directory and child name into a normalized absolute path.
String joinRemotePath(String directory, String name) {
  final baseDirectory =
      normalizeSftpAbsolutePath(directory) ??
      (directory.isEmpty ? '/' : _normalizeSftpPathSeparators(directory));
  final nameWithRemoteSeparators =
      _splitSftpWindowsDriveRoot(baseDirectory) == null
      ? name
      : _normalizeSftpPathSeparators(name);
  final cleanName = nameWithRemoteSeparators.replaceFirst(RegExp('^/+'), '');
  final joined = path.posix.join(baseDirectory, cleanName);
  final normalized = normalizeSftpAbsolutePath(joined);
  if (normalized != null) {
    return normalized;
  }
  final normalizedRelative = path.posix.normalize(joined);
  return normalizedRelative.startsWith('/')
      ? normalizedRelative
      : '/$normalizedRelative';
}

/// Normalizes an absolute remote path by collapsing `.`, `..`, and extra `/`.
String? normalizeSftpAbsolutePath(String? remotePath) {
  final trimmedPath = remotePath?.trim();
  if (trimmedPath == null || trimmedPath.isEmpty) {
    return null;
  }

  final normalizedSeparators = _normalizeSftpPathSeparators(trimmedPath);
  final windowsRoot = _splitSftpWindowsDriveRoot(normalizedSeparators);
  if (windowsRoot != null) {
    final segments = _normalizeSftpPathSegments(windowsRoot.rest);
    return segments.isEmpty
        ? windowsRoot.root
        : '${windowsRoot.root}${segments.join('/')}';
  }

  if (!normalizedSeparators.startsWith('/')) {
    return null;
  }

  final segments = _normalizeSftpPathSegments(normalizedSeparators);
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

  if (isSftpAbsolutePath(trimmedPath)) {
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
  // A name made only of dots (`.`, `..`) is a path-traversal token rather than a
  // file, so fall back to a literal name even though it survives the allowlist.
  if (sanitized.isEmpty || RegExp(r'^\.+$').hasMatch(sanitized)) {
    return 'file';
  }
  return sanitized;
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

/// Whether [path] is safe to paste unquoted (only path separators and the
/// strict upload-filename allowlist). Uploaded filenames are sanitized, but the
/// directory prefix derives from the remote home directory, which a hostile or
/// misconfigured server could fill with spaces or shell metacharacters.
bool _isUnquotedSafeAttachmentPath(String path) =>
    RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(path);

/// Builds the terminal-input segments that reference uploaded [remotePaths]
/// after a paste upload.
///
/// When [bracketedPasteMode] is enabled *and* every path is safe to paste
/// unquoted, each path is returned as its own bracketed-paste segment
/// (`CSI 200~ <path> CSI 201~ ` with a trailing space). The caller must write
/// these segments sequentially with a short delay between them: an agent CLI
/// such as Copilot CLI only recognises each path as a separate attachment —
/// rendering a preview chip per file — when the bracketed pastes arrive as
/// distinct reads. The trailing space also keeps the paths usable as distinct
/// shell arguments.
///
/// Otherwise — bracketed paste mode is off, or a path contains characters that
/// would be unsafe unquoted (e.g. a remote home directory with spaces or shell
/// metacharacters) — the paths are shell-escaped and returned as a single
/// segment. That form shows no preview (a path with spaces would not produce a
/// chip anyway) but can never break the shell or inject commands.
///
/// Segments must be written straight to the session input sink (e.g.
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
  final canRenderChips =
      bracketedPasteMode && paths.every(_isUnquotedSafeAttachmentPath);
  if (!canRenderChips) {
    return ['${paths.map(shellEscapePosix).join(' ')} '];
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

    final parentPath = parentSftpPath(remotePath);
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
