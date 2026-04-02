import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Returns whether the current platform can scan recovery-key QR codes.
bool supportsRecoveryKeyQrScanning(TargetPlatform platform) {
  if (kIsWeb) {
    return true;
  }
  return switch (platform) {
    TargetPlatform.android || TargetPlatform.iOS => true,
    TargetPlatform.macOS ||
    TargetPlatform.fuchsia ||
    TargetPlatform.linux ||
    TargetPlatform.windows => false,
  };
}

/// Shows the recovery key as both text and a QR code.
Future<void> showRecoveryKeyQrDialog(
  BuildContext context,
  String recoveryKey,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Sync recovery key'),
      content: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Save this key somewhere safe. You need it to set up another device or recover encrypted sync access.',
            ),
            const SizedBox(height: 16),
            SelectableText(
              recoveryKey,
              style: Theme.of(dialogContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            Center(
              child: SizedBox.square(
                dimension: 244,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: ColoredBox(
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: QrImageView(
                        data: recoveryKey,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// Prompts for a recovery key and optionally scans a QR code.
Future<String?> showRecoveryKeyEntryDialog(BuildContext context) async {
  final controller = TextEditingController();
  final canScanQr = supportsRecoveryKeyQrScanning(defaultTargetPlatform);
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Enter recovery key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Recovery key',
                helperText:
                    'Used to decrypt and enroll this device into the sync vault',
              ),
              textCapitalization: TextCapitalization.characters,
              maxLines: 2,
            ),
            if (canScanQr) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final scannedRecoveryKey = await _showRecoveryKeyQrScanner(
                    dialogContext,
                  );
                  if (!dialogContext.mounted || scannedRecoveryKey == null) {
                    return;
                  }
                  final trimmedRecoveryKey = scannedRecoveryKey.trim();
                  controller.value = TextEditingValue(
                    text: trimmedRecoveryKey,
                    selection: TextSelection.collapsed(
                      offset: trimmedRecoveryKey.length,
                    ),
                  );
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR code'),
              ),
            ],
          ],
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
    );
  } finally {
    controller.dispose();
  }
}

Future<String?> _showRecoveryKeyQrScanner(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (dialogContext) => const _RecoveryKeyQrScannerDialog(),
    );

class _RecoveryKeyQrScannerDialog extends StatefulWidget {
  const _RecoveryKeyQrScannerDialog();

  @override
  State<_RecoveryKeyQrScannerDialog> createState() =>
      _RecoveryKeyQrScannerDialogState();
}

class _RecoveryKeyQrScannerDialogState
    extends State<_RecoveryKeyQrScannerDialog> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _didScanCode = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDetection(BarcodeCapture capture) {
    if (_didScanCode) {
      return;
    }
    final value = capture.barcodes
        .map((barcode) => barcode.rawValue?.trim())
        .whereType<String>()
        .firstWhere((barcode) => barcode.isNotEmpty, orElse: () => '');
    if (value.isEmpty || !mounted) {
      return;
    }
    _didScanCode = true;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Scan recovery key QR code'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ColoredBox(
              color: Colors.black,
              child: MobileScanner(
                controller: _controller,
                onDetect: _handleDetection,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Point the camera at a recovery key QR code from another device.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    ),
  );
}
