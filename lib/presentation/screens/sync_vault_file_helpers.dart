import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'transfer_screen.dart';

/// File extension used for encrypted MonkeySSH sync vault files.
const monkeySshSyncVaultFileExtension = 'monkeysync';

const _maxSyncVaultBytes = 10 * 1024 * 1024;

/// Result of selecting an encrypted sync vault file from disk.
class SelectedSyncVaultFile {
  /// Creates a new [SelectedSyncVaultFile].
  const SelectedSyncVaultFile({required this.contents, required this.path});

  /// Full file contents read from the selected vault file.
  final String contents;

  /// Filesystem path for the selected file, if the platform provides one.
  final String? path;
}

/// Saves an encrypted sync vault file and returns the selected output path.
Future<String?> saveSyncVaultToFile({
  required BuildContext context,
  required String encryptedVault,
  required String defaultFileName,
}) async {
  final bytes = Uint8List.fromList(utf8.encode(encryptedVault));
  final sanitizedBaseName = sanitizeTransferFileBaseName(defaultFileName);
  final targetPath = await FilePicker.platform.saveFile(
    dialogTitle: 'Save encrypted MonkeySSH sync vault',
    fileName: '$sanitizedBaseName.$monkeySshSyncVaultFileExtension',
    type: FileType.custom,
    allowedExtensions: const [monkeySshSyncVaultFileExtension],
    bytes: bytes,
  );

  if (!context.mounted) {
    return null;
  }

  if (targetPath == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Sync vault setup cancelled')));
    return null;
  }

  final shouldWriteFileDirectly =
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
  if (shouldWriteFileDirectly) {
    try {
      await _writeBytesAtomically(File(targetPath), bytes);
    } on FileSystemException {
      if (!context.mounted) {
        return null;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to write sync vault file')),
      );
      return null;
    }
  }

  return targetPath;
}

/// Opens an encrypted sync vault file selected by the user.
Future<SelectedSyncVaultFile?> pickSyncVaultFromFile(
  BuildContext context,
) async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Select encrypted MonkeySSH sync vault',
    type: FileType.custom,
    allowedExtensions: const [monkeySshSyncVaultFileExtension],
    withData: kIsWeb,
  );

  if (result == null || result.files.isEmpty) {
    return null;
  }

  final file = result.files.single;
  final bytes = file.bytes;
  if (bytes != null && bytes.isNotEmpty) {
    if (bytes.length > _maxSyncVaultBytes) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync vault file is too large')),
        );
      }
      return null;
    }
    try {
      return SelectedSyncVaultFile(
        contents: utf8.decode(bytes),
        path: file.path,
      );
    } on FormatException {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid sync vault file format')),
        );
      }
      return null;
    }
  }

  final path = file.path;
  if (path == null || path.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read the selected sync vault')),
      );
    }
    return null;
  }

  final localFile = File(path);
  try {
    final length = await localFile.length();
    if (length > _maxSyncVaultBytes) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync vault file is too large')),
        );
      }
      return null;
    }
    return SelectedSyncVaultFile(
      contents: await localFile.readAsString(),
      path: path,
    );
  } on FileSystemException {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read the selected sync vault')),
      );
    }
    return null;
  } on FormatException {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid sync vault file format')),
      );
    }
    return null;
  }
}

Future<void> _writeBytesAtomically(File targetFile, Uint8List bytes) async {
  final tempFile = File(
    '${targetFile.parent.path}/.${targetFile.uri.pathSegments.last}.tmp',
  );
  await tempFile.writeAsBytes(bytes, flush: true);
  try {
    await tempFile.rename(targetFile.path);
  } on FileSystemException {
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await tempFile.rename(targetFile.path);
  }
}
