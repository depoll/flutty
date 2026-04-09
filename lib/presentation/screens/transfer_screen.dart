import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/app_metadata.dart';
import '../../domain/services/auth_service.dart';
import '../../domain/services/secure_transfer_service.dart';
import '../widgets/file_picker_helpers.dart';

/// File extension used for encrypted MonkeySSH transfer packages.
const monkeySshTransferFileExtension = 'monkeysshx';

/// MIME type for encrypted transfer packages.
const monkeySshTransferMimeType = 'application/x-monkeyssh-transfer';
const _maxTransferPayloadBytes = 10 * 1024 * 1024;

/// Whether the current platform uses the system share sheet for exports.
///
/// On iOS and Android the share sheet provides AirDrop, Quick Share, Messages,
/// email, Save to Files, and other targets. Desktop platforms keep the
/// file-save dialog.
bool get useShareSheet => !kIsWeb && (Platform.isIOS || Platform.isAndroid);

/// Computes the share sheet anchor rect from a widget's [BuildContext].
///
/// Required on iPad where the share popover must attach to a source rect.
Rect? shareOriginFromContext(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Exports an encrypted transfer payload.
///
/// On mobile (iOS/Android) this opens the system share sheet so the user can
/// AirDrop, Quick Share, save to Files, or send via any installed app.
/// On desktop and web it falls back to a file-save dialog.
Future<void> saveTransferPayloadToFile({
  required BuildContext context,
  required String payload,
  required String defaultFileName,
  Rect? sharePositionOrigin,
}) async {
  final bytes = Uint8List.fromList(utf8.encode(payload));
  final sanitizedBaseName = sanitizeTransferFileBaseName(defaultFileName);
  final fileName = '$sanitizedBaseName.$monkeySshTransferFileExtension';

  if (useShareSheet) {
    await _sharePayloadViaNativeSheet(
      context: context,
      bytes: bytes,
      fileName: fileName,
      sharePositionOrigin: sharePositionOrigin,
    );
    return;
  }

  await _savePayloadToFileDialog(
    context: context,
    bytes: bytes,
    fileName: fileName,
  );
}

/// Opens the system share sheet with the transfer file attached.
Future<void> _sharePayloadViaNativeSheet({
  required BuildContext context,
  required Uint8List bytes,
  required String fileName,
  Rect? sharePositionOrigin,
}) async {
  final tempDir = await getTemporaryDirectory();
  final tempFile = File(p.join(tempDir.path, fileName));
  try {
    await tempFile.writeAsBytes(bytes, flush: true);
  } on FileSystemException {
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Failed to prepare transfer file')),
    );
    return;
  }

  try {
    if (!context.mounted) {
      return;
    }

    final result = await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            tempFile.path,
            mimeType: monkeySshTransferMimeType,
            name: fileName,
          ),
        ],
        sharePositionOrigin: sharePositionOrigin,
      ),
    );

    if (!context.mounted) {
      return;
    }

    if (result.status == ShareResultStatus.dismissed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Share cancelled')));
    }
  } on Object catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'transfer',
        context: ErrorDescription('while sharing transfer file'),
      ),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to open share sheet')),
      );
    }
  } finally {
    try {
      if (tempFile.existsSync()) {
        await tempFile.delete();
      }
    } on FileSystemException {
      // Best-effort cleanup; the OS will reclaim temp storage.
    }
  }
}

/// Saves the transfer payload via a native file-save dialog (desktop / web).
Future<void> _savePayloadToFileDialog({
  required BuildContext context,
  required Uint8List bytes,
  required String fileName,
}) async {
  final appName = await loadAppName();
  final targetPath = await FilePicker.platform.saveFile(
    dialogTitle: 'Export encrypted $appName transfer file',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const [monkeySshTransferFileExtension],
    bytes: bytes,
  );

  if (!context.mounted) {
    return;
  }

  if (targetPath == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Export cancelled')));
    return;
  }

  final shouldWriteFileDirectly =
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);
  if (shouldWriteFileDirectly) {
    try {
      await File(targetPath).writeAsBytes(bytes, flush: true);
    } on FileSystemException {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to write transfer file')),
      );
      return;
    }
  }
  if (!context.mounted) {
    return;
  }

  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Encrypted file saved: $targetPath')));
}

/// Imports payload content from an encrypted transfer file.
Future<String?> pickTransferPayloadFromFile(BuildContext context) async {
  final appName = await loadAppName();
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Select encrypted $appName transfer file',
    type: pickerFileTypeForCustomExtension(defaultTargetPlatform),
    allowedExtensions: pickerAllowedExtensionsForCustomExtension(
      defaultTargetPlatform,
      const [monkeySshTransferFileExtension],
    ),
    withData: kIsWeb,
  );

  if (result == null || result.files.isEmpty) {
    return null;
  }

  final selectedFile = result.files.single;
  if (!platformFileMatchesExpectedExtension(
    selectedFile,
    monkeySshTransferFileExtension,
  )) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a .monkeysshx transfer file')),
      );
    }
    return null;
  }

  final bytes = selectedFile.bytes;
  if (bytes != null && bytes.isNotEmpty) {
    if (bytes.length > _maxTransferPayloadBytes) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transfer file is too large')),
        );
      }
      return null;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid transfer file format')),
        );
      }
      return null;
    }
  }

  final path = selectedFile.path;
  if (path == null || path.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read selected transfer file')),
      );
    }
    return null;
  }

  final file = File(path);
  try {
    final length = await file.length();
    if (length > _maxTransferPayloadBytes) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Transfer file is too large')),
        );
      }
      return null;
    }
    return await file.readAsString();
  } on FileSystemException {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read selected transfer file')),
      );
    }
    return null;
  } on FormatException {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid transfer file format')),
      );
    }
    return null;
  }
}

/// Dialog that asks for transfer passphrase.
Future<String?> showTransferPassphraseDialog({
  required BuildContext context,
  required String title,
}) async {
  final controller = TextEditingController();
  var obscureText = true;

  final value = await showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          obscureText: obscureText,
          decoration: InputDecoration(
            labelText: 'Transfer passphrase',
            helperText: 'Required to encrypt/decrypt transfer data',
            suffixIcon: IconButton(
              onPressed: () => setState(() => obscureText = !obscureText),
              icon: Icon(obscureText ? Icons.visibility : Icons.visibility_off),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    ),
  );

  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return trimmed;
}

/// Requests local authentication for sensitive transfer exports.
Future<bool> authorizeSensitiveTransferExport({
  required BuildContext context,
  required AuthService authService,
  required AuthState Function() readAuthState,
  required String reason,
}) async {
  final isAuthEnabled = await authService.isAuthEnabled();
  if (!isAuthEnabled || !context.mounted) {
    return true;
  }

  AuthMethod method;
  try {
    method = await authService.getAuthMethod();
  } on Object catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'auth',
        context: ErrorDescription(
          'while determining the available authentication method for sensitive transfers',
        ),
      ),
    );
    return false;
  }
  if (!context.mounted) {
    return false;
  }

  switch (method) {
    case AuthMethod.none:
      return true;
    case AuthMethod.biometric:
      final biometricSuccess = await authService.authenticateWithBiometrics(
        reason: reason,
      );
      if (!_isSensitiveTransferAuthSessionUnlocked(readAuthState)) {
        return false;
      }
      return biometricSuccess;
    case AuthMethod.pin:
      final pin = await _showPinDialog(context);
      if (pin == null) {
        return false;
      }
      return authService.verifyPin(pin);
    case AuthMethod.both:
      final biometricSuccess = await authService.authenticateWithBiometrics(
        reason: reason,
      );
      if (!_isSensitiveTransferAuthSessionUnlocked(readAuthState)) {
        return false;
      }
      if (biometricSuccess) {
        return true;
      }
      if (!context.mounted) {
        return false;
      }
      final pin = await _showPinDialog(context);
      if (pin == null) {
        return false;
      }
      return authService.verifyPin(pin);
  }
}

bool _isSensitiveTransferAuthSessionUnlocked(
  AuthState Function() readAuthState,
) => readAuthState() == AuthState.unlocked;

Future<String?> _showPinDialog(BuildContext context) async {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Enter PIN'),
      content: TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'PIN'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}

/// Shared merge/replace mode chooser for migration imports.
Future<MigrationImportMode?> showMigrationImportModeDialog({
  required BuildContext context,
  required MigrationPreview preview,
  required String title,
  String message = 'Choose how to apply imported data.',
}) async => showDialog<MigrationImportMode>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Settings: ${preview.settingsCount}'),
        Text('Hosts: ${preview.hostCount}'),
        Text('Keys: ${preview.keyCount}'),
        Text('Groups: ${preview.groupCount}'),
        Text('Snippets: ${preview.snippetCount}'),
        Text('Snippet folders: ${preview.snippetFolderCount}'),
        Text('Port forwards: ${preview.portForwardCount}'),
        Text('Known hosts: ${preview.knownHostCount}'),
        const SizedBox(height: 12),
        Text(message),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      OutlinedButton(
        onPressed: () => Navigator.pop(context, MigrationImportMode.merge),
        child: const Text('Merge'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, MigrationImportMode.replace),
        child: const Text('Replace'),
      ),
    ],
  ),
);
