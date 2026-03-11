// ignore_for_file: public_member_api_docs

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/services/transfer_intent_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const transferChannel = MethodChannel('xyz.depollsoft.monkeyssh/transfer');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(transferChannel, null);
  });

  group('TransferIntentService', () {
    test(
      'returns null when the native transfer channel is unavailable',
      () async {
        final service = TransferIntentService();

        final payload = await service.consumeIncomingTransferPayload();

        expect(payload, isNull);
        await service.dispose();
      },
    );

    test(
      'returns the pending payload from the native transfer channel',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(transferChannel, (call) async {
              if (call.method == 'consumeIncomingTransferPayload') {
                return 'encoded-transfer-payload';
              }
              return null;
            });

        final service = TransferIntentService();

        final payload = await service.consumeIncomingTransferPayload();

        expect(payload, 'encoded-transfer-payload');
        await service.dispose();
      },
    );
  });
}
