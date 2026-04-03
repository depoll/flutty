import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Maximum supported size for an encrypted sync vault file.
const maxSyncVaultBytes = 10 * 1024 * 1024;

const _syncVaultFileIoUuid = Uuid();

/// Replaces [targetFile] contents with [bytes] while preserving the existing
/// vault file if the final swap cannot be completed.
Future<void> writeBytesToFileAtomically(
  File targetFile,
  List<int> bytes,
) async {
  final tempFile = File(
    p.join(
      targetFile.parent.path,
      '.${p.basename(targetFile.path)}.${_syncVaultFileIoUuid.v4()}.tmp',
    ),
  );
  await tempFile.writeAsBytes(bytes, flush: true);

  File? backupFile;
  try {
    try {
      await tempFile.rename(targetFile.path);
      return;
    } on FileSystemException {
      // ignore: avoid_slow_async_io
      if (!await targetFile.exists()) {
        rethrow;
      }
    }

    backupFile = File(
      p.join(
        targetFile.parent.path,
        '.${p.basename(targetFile.path)}.${_syncVaultFileIoUuid.v4()}.bak',
      ),
    );
    await targetFile.rename(backupFile.path);
    try {
      await tempFile.rename(targetFile.path);
    } on FileSystemException {
      try {
        await backupFile.rename(targetFile.path);
      } on FileSystemException {
        // Leave the backup in place so the previous vault contents still exist.
      }
      rethrow;
    }
    // ignore: avoid_slow_async_io
    if (await backupFile.exists()) {
      try {
        await backupFile.delete();
      } on FileSystemException {
        // The new vault is already in place, so cleanup is best-effort only.
      }
    }
  } finally {
    // ignore: avoid_slow_async_io
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }
}

/// Replaces [targetFile] contents with [contents] while preserving the
/// existing vault file if the final swap cannot be completed.
Future<void> writeStringToFileAtomically(File targetFile, String contents) =>
    writeBytesToFileAtomically(targetFile, utf8.encode(contents));
