// ignore_for_file: public_member_api_docs

import 'dart:io' show gzip;

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
      final binaryBytes = switch (entry.encoding) {
        null || '' || 'none' => assetBytes,
        'gzip' => Uint8List.fromList(gzip.decode(assetBytes)),
        final encoding => throw StateError(
          'Unsupported MonkeyMux asset encoding: $encoding',
        ),
      };

      expect(entry.encoding, 'gzip', reason: entry.asset);
      expect(entry.asset, endsWith('.gz'));
      expect(binaryBytes.length, entry.size, reason: entry.asset);
      expect(sha256.convert(binaryBytes).toString(), entry.sha256);
    }
  });
}
