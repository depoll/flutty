import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Service that consumes transfer payloads opened from external files.
class TransferIntentService {
  static const _channel = MethodChannel('xyz.depollsoft.monkeyssh/transfer');
  static const _duplicateDeliveryWindow = Duration(seconds: 5);
  final _incomingController = StreamController<String>.broadcast();
  final _recentLivePayloads = <String, DateTime>{};
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
      final payload = await _channel.invokeMethod<String>(
        'consumeIncomingTransferPayload',
      );
      final normalizedPayload = _normalizePayload(payload);
      if (normalizedPayload == null) {
        return null;
      }
      _pruneRecentLivePayloads();
      final lastLiveDelivery = _recentLivePayloads[normalizedPayload];
      if (lastLiveDelivery == null) {
        return normalizedPayload;
      }
      if (DateTime.now().difference(lastLiveDelivery) <=
          _duplicateDeliveryWindow) {
        return null;
      }
      _recentLivePayloads.remove(normalizedPayload);
      return normalizedPayload;
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
      final payload = _normalizePayload(call.arguments);
      if (payload != null) {
        _pruneRecentLivePayloads();
        _recentLivePayloads[payload] = DateTime.now();
        _incomingController.add(payload);
      }
    });
  }

  String? _normalizePayload(Object? payload) {
    if (payload is! String) {
      return null;
    }
    final normalizedPayload = payload.trim();
    if (normalizedPayload.isEmpty) {
      return null;
    }
    return normalizedPayload;
  }

  void _pruneRecentLivePayloads() {
    final cutoff = DateTime.now().subtract(_duplicateDeliveryWindow);
    _recentLivePayloads.removeWhere(
      (_, deliveredAt) => deliveredAt.isBefore(cutoff),
    );
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
