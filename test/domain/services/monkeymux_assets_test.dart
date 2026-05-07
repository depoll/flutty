// ignore_for_file: public_member_api_docs

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/monkeymux_installer_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled MonkeyMux assets match the manifest', () async {
    final manifest = await MonkeyMuxManifest.load();

    expect(manifest.entries, isNotEmpty);
    for (final entry in manifest.entries) {
      final bytes = await rootBundle.load(entry.asset);
      final assetBytes = bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );

      expect(assetBytes.length, entry.size, reason: entry.asset);
      expect(sha256.convert(assetBytes).toString(), entry.sha256);
    }
  });
}
