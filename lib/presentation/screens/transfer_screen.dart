import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// File extension used for encrypted MonkeySSH transfer packages.
const monkeySshTransferFileExtension = 'monkeysshx';

/// Source options for transfer imports.
enum TransferImportSource {
  /// Scan a transfer QR code.
  qr,

  /// Read an encrypted transfer file.
  file,
}

/// Screen that displays a transfer payload as QR and encrypted file export.
class TransferQrScreen extends StatelessWidget {
  /// Creates a new [TransferQrScreen].
  const TransferQrScreen({
    required this.title,
    required this.payload,
    required this.defaultFileName,
    super.key,
  });

  /// Screen title.
  final String title;

  /// Encrypted payload content.
  final String payload;

  /// Suggested file name without extension.
  final String defaultFileName;

  static const _qrWarningThreshold = 2600;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final payloadLength = payload.length;
    final showQr = payloadLength <= _qrWarningThreshold;

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  if (showQr) ...[
                    QrImageView(
                      data: payload,
                      size: 260,
                      backgroundColor: Colors.white,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Scan in MonkeySSH on your other device',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ] else ...[
                    Icon(
                      Icons.qr_code_2,
                      size: 72,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Payload is too large for reliable QR scanning.',
                      style: theme.textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Use encrypted file export for AirDrop transfer.',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Encrypted payload length: $payloadLength',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () async {
              await saveTransferPayloadToFile(
                context: context,
                payload: payload,
                defaultFileName: defaultFileName,
              );
            },
            icon: const Icon(Icons.save_alt),
            label: const Text('Export Encrypted File'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: payload));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Encrypted payload copied')),
                );
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy Encrypted Payload'),
          ),
        ],
      ),
    );
  }
}

/// Exports payload bytes to an encrypted transfer file.
Future<void> saveTransferPayloadToFile({
  required BuildContext context,
  required String payload,
  required String defaultFileName,
}) async {
  final bytes = Uint8List.fromList(utf8.encode(payload));
  final targetPath = await FilePicker.platform.saveFile(
    dialogTitle: 'Export encrypted MonkeySSH transfer file',
    fileName: '$defaultFileName.$monkeySshTransferFileExtension',
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

  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('Encrypted file saved: $targetPath')));
}

/// Prompts for transfer import source.
Future<TransferImportSource?> showTransferImportSourceSheet(
  BuildContext context,
) async => showModalBottomSheet<TransferImportSource>(
  context: context,
  builder: (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: const Icon(Icons.qr_code_scanner),
          title: const Text('Scan QR'),
          onTap: () => Navigator.pop(context, TransferImportSource.qr),
        ),
        ListTile(
          leading: const Icon(Icons.file_open),
          title: const Text('Import Encrypted File (.monkeysshx)'),
          onTap: () => Navigator.pop(context, TransferImportSource.file),
        ),
      ],
    ),
  ),
);

/// Starts scanner and returns scanned payload text.
Future<String?> scanTransferPayload(BuildContext context) async =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const TransferScannerScreen()),
    );

/// Imports payload content from an encrypted transfer file.
Future<String?> pickTransferPayloadFromFile(BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Select encrypted MonkeySSH transfer file',
    type: FileType.custom,
    allowedExtensions: const [monkeySshTransferFileExtension],
    withData: true,
  );

  if (result == null || result.files.isEmpty) {
    return null;
  }

  final bytes = result.files.single.bytes;
  if (bytes == null || bytes.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read selected transfer file')),
      );
    }
    return null;
  }

  return utf8.decode(bytes);
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

/// Camera-based scanner for MonkeySSH transfer QR payloads.
class TransferScannerScreen extends StatefulWidget {
  /// Creates a new [TransferScannerScreen].
  const TransferScannerScreen({super.key});

  @override
  State<TransferScannerScreen> createState() => _TransferScannerScreenState();
}

class _TransferScannerScreenState extends State<TransferScannerScreen> {
  bool _isHandled = false;
  final _controller = MobileScannerController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan Transfer QR')),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            if (_isHandled) {
              return;
            }
            String? rawValue;
            for (final barcode in capture.barcodes) {
              if (barcode.rawValue != null &&
                  barcode.rawValue!.trim().isNotEmpty) {
                rawValue = barcode.rawValue!.trim();
                break;
              }
            }
            if (rawValue == null || rawValue.trim().isEmpty) {
              return;
            }
            _isHandled = true;
            Navigator.of(context).pop(rawValue);
          },
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Card(
            color: Colors.black.withAlpha(150),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Point camera at a MonkeySSH transfer QR code',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
