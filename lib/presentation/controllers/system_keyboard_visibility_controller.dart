import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform-authoritative soft-keyboard visibility shared by every text input.
///
/// `MediaQuery.viewInsets` is primarily layout geometry and can remain stale
/// after the IME closes. Android reports `WindowInsetsCompat.Type.ime()`
/// visibility and iOS reports keyboard lifecycle notifications over this
/// channel, giving terminal and native composer layouts one common authority.
class SystemKeyboardVisibilityController extends ChangeNotifier {
  SystemKeyboardVisibilityController._();

  /// Process-wide controller for the shared Flutter engine.
  static final instance = SystemKeyboardVisibilityController._();

  static const _channel = MethodChannel(
    'xyz.depollsoft.monkeyssh/keyboard_visibility',
  );

  bool _initialized = false;
  bool? _visible;

  /// Authoritative platform state, or `null` before a platform responds.
  bool? get visible => _visible;

  /// Starts native visibility delivery and queries the current state.
  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleMethodCall);
    try {
      _setVisible(await _channel.invokeMethod<bool>('getVisibility'));
    } on MissingPluginException {
      // Desktop/web and older native shells use the input-owner fallback.
    } on PlatformException {
      // Visibility is advisory; layout remains functional via the fallback.
    }
  }

  Future<Object?> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onVisibilityChanged') {
      _setVisible(call.arguments as bool?);
    }
    return null;
  }

  void _setVisible(bool? value) {
    if (value == null || value == _visible) return;
    _visible = value;
    notifyListeners();
  }

  /// Overrides native visibility for deterministic layout tests.
  @visibleForTesting
  void debugSetVisible({required bool? visible}) {
    if (visible == _visible) return;
    _visible = visible;
    notifyListeners();
  }
}
