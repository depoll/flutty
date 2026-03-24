import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../domain/services/auth_service.dart';
import '../../domain/services/secure_transfer_service.dart';

/// File extension used for encrypted MonkeySSH transfer packages.
const monkeySshTransferFileExtension = 'monkeysshx';
const _maxTransferPayloadBytes = 10 * 1024 * 1024;
const _defaultTransferFileBaseName = 'monkeyssh-transfer';

/// Normalizes a suggested transfer export filename into a filesystem-safe base.
String sanitizeTransferFileBaseName(String input) {
  final normalized = input
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '-')
      .replaceAll(RegExp(r'\s+'), '-')
      .replaceAll(RegExp('-+'), '-')
      .replaceAll(RegExp(r'^\.+|\.+$'), '')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return normalized.isEmpty ? _defaultTransferFileBaseName : normalized;
}

/// Exports payload bytes to an encrypted transfer file.
Future<void> saveTransferPayloadToFile({
  required BuildContext context,
  required String payload,
  required String defaultFileName,
}) async {
  final bytes = Uint8List.fromList(utf8.encode(payload));
  final sanitizedBaseName = sanitizeTransferFileBaseName(defaultFileName);
  final targetPath = await FilePicker.platform.saveFile(
    dialogTitle: 'Export encrypted MonkeySSH transfer file',
    fileName: '$sanitizedBaseName.$monkeySshTransferFileExtension',
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
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Select encrypted MonkeySSH transfer file',
    type: FileType.custom,
    allowedExtensions: const [monkeySshTransferFileExtension],
    withData: kIsWeb,
  );

  if (result == null || result.files.isEmpty) {
    return null;
  }

  final bytes = result.files.single.bytes;
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

  final path = result.files.single.path;
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
      return authService.authenticateWithBiometrics(reason: reason);
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
