import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Service that consumes transfer payloads opened from external files.
class TransferIntentService {
  static const _channel = MethodChannel('xyz.depollsoft.monkeyssh/transfer');
  final _incomingController = StreamController<String>.broadcast();
  bool _initialized = false;

  /// Stream of incoming transfer payloads forwarded by native platforms.
  Stream<String> get incomingPayloads {
    _ensureInitialized();
    return _incomingController.stream;
  }

  /// Returns and clears a pending incoming transfer payload, if any.
  Future<String?> consumeIncomingTransferPayload() async {
    _ensureInitialized();
    try {
      return _channel.invokeMethod<String>('consumeIncomingTransferPayload');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onIncomingTransferPayload') {
        return;
      }
      final payload = call.arguments;
      if (payload is String && payload.trim().isNotEmpty) {
        _incomingController.add(payload.trim());
      }
    });
  }

  /// Releases resources held by the service.
  Future<void> dispose() async {
    if (_initialized) {
      _channel.setMethodCallHandler(null);
    }
    await _incomingController.close();
  }
}

/// Provider for [TransferIntentService].
final transferIntentServiceProvider = Provider<TransferIntentService>((ref) {
  final service = TransferIntentService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
