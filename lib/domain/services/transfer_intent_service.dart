import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Service that consumes transfer payloads opened from external files.
class TransferIntentService {
  static const _channel = MethodChannel('xyz.depollsoft.monkeyssh/transfer');

  /// Returns and clears a pending incoming transfer payload, if any.
  Future<String?> consumeIncomingTransferPayload() async {
    try {
      return _channel.invokeMethod<String>('consumeIncomingTransferPayload');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

/// Provider for [TransferIntentService].
final transferIntentServiceProvider = Provider<TransferIntentService>(
  (ref) => TransferIntentService(),
);
