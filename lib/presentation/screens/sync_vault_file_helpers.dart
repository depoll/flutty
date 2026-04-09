import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_metadata.dart';
import '../../domain/services/sync_vault_document_service.dart';
import '../../domain/services/sync_vault_file_io.dart';
import '../widgets/file_picker_helpers.dart';

/// File extension used for encrypted MonkeySSH sync vault files.
const monkeySshSyncVaultFileExtension = 'monkeysync';

/// Result of selecting an encrypted sync vault file from disk.
class SelectedSyncVaultFile {
  /// Creates a new [SelectedSyncVaultFile].
  const SelectedSyncVaultFile({
    required this.contents,
    required this.path,
    this.bookmark,
  });

  /// Full file contents read from the selected vault file.
  final String contents;

  /// Filesystem path for the selected file.
  final String path;

  /// Security-scoped bookmark used by iOS to reopen the linked file later.
  final String? bookmark;
}

/// Result of saving a new encrypted sync vault file.
class SavedSyncVaultFile {
  /// Creates a new [SavedSyncVaultFile].
  const SavedSyncVaultFile({required this.path, this.bookmark});

  /// Stored label for the saved file.
  final String path;

  /// Security-scoped bookmark used by iOS to reopen the linked file later.
  final String? bookmark;
}

/// Saves an encrypted sync vault file and returns the selected output path.
Future<SavedSyncVaultFile?> saveSyncVaultToFile({
  required BuildContext context,
  required SyncVaultDocumentService documentService,
  required String encryptedVault,
  required String defaultFileName,
}) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      final linkedVault = await documentService.createLinkedVault(
        encryptedVault: encryptedVault,
        suggestedFileName: '$defaultFileName.$monkeySshSyncVaultFileExtension',
      );
      if (!context.mounted) {
        return null;
      }
      if (linkedVault == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync vault setup cancelled')),
        );
        return null;
      }
      return SavedSyncVaultFile(
        path: linkedVault.path,
        bookmark: linkedVault.bookmark,
      );
    } on FormatException catch (error) {
      if (!context.mounted) {
        return null;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
      return null;
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

  final bytes = Uint8List.fromList(utf8.encode(encryptedVault));
  final sanitizedBaseName = sanitizeTransferFileBaseName(defaultFileName);
  final appName = await loadAppName();
  final targetPath = await FilePicker.platform.saveFile(
    dialogTitle: 'Save encrypted $appName sync vault',
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

  return SavedSyncVaultFile(path: targetPath);
}

/// Opens an encrypted sync vault file selected by the user.
Future<SelectedSyncVaultFile?> pickSyncVaultFromFile(
  BuildContext context,
  SyncVaultDocumentService documentService,
) async {
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    try {
      final linkedVault = await documentService.pickLinkedVault();
      if (linkedVault == null) {
        return null;
      }
      return SelectedSyncVaultFile(
        contents: linkedVault.contents,
        path: linkedVault.path,
        bookmark: linkedVault.bookmark,
      );
    } on FormatException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
      return null;
    } on FileSystemException {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not read the selected sync vault'),
          ),
        );
      }
      return null;
    }
  }

  final appName = await loadAppName();
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Select encrypted $appName sync vault',
    type: pickerFileTypeForCustomExtension(defaultTargetPlatform),
    allowedExtensions: pickerAllowedExtensionsForCustomExtension(
      defaultTargetPlatform,
      const [monkeySshSyncVaultFileExtension],
    ),
    withData: kIsWeb,
  );

  if (result == null || result.files.isEmpty) {
    return null;
  }

  final file = result.files.single;
  if (!platformFileMatchesExpectedExtension(
    file,
    monkeySshSyncVaultFileExtension,
  )) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a .monkeysync sync vault file')),
      );
    }
    return null;
  }
  final bytes = file.bytes;
  if (bytes != null && bytes.isNotEmpty) {
    if (bytes.length > maxSyncVaultBytes) {
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
        path: file.path ?? file.name,
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
    if (length > maxSyncVaultBytes) {
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
  await writeBytesToFileAtomically(targetFile, bytes);
}
