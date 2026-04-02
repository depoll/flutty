import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/widgets/recovery_key_qr_dialogs.dart';

void main() {
  test('supports QR scanning on iOS but not macOS', () {
    expect(supportsRecoveryKeyQrScanning(TargetPlatform.iOS), isTrue);
    expect(supportsRecoveryKeyQrScanning(TargetPlatform.macOS), isFalse);
  });
}
