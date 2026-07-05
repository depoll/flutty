import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Navigator observer that clears a stale soft-keyboard inset after a route
/// transition.
///
/// When a route that had the on-screen keyboard open is dismissed (for example
/// closing a modal sheet or returning from the terminal), the platform can keep
/// reserving space for the keyboard even though the keyboard itself is no longer
/// visible. That phantom bottom inset shrinks the revealed screen, leaving a
/// blank gap and — on scrollable screens such as settings — making content look
/// like it failed to render.
///
/// After every push/pop/replace/remove this observer asks the platform to hide
/// the keyboard, which forces the bottom view inset to be recomputed. The hide
/// request is skipped whenever a real input is focused, so screens that
/// intentionally show the keyboard (an autofocused field, the terminal) are
/// never disturbed.
class KeyboardDismissRouteObserver extends NavigatorObserver {
  /// Creates a [KeyboardDismissRouteObserver].
  KeyboardDismissRouteObserver();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _dismissKeyboardWhenUnfocused();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    _dismissKeyboardWhenUnfocused();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didRemove(route, previousRoute);
    _dismissKeyboardWhenUnfocused();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    _dismissKeyboardWhenUnfocused();
  }

  void _dismissKeyboardWhenUnfocused() {
    // Defer to the next frame so focus has settled on the revealed route before
    // deciding whether the keyboard is still wanted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final primaryFocus = FocusManager.instance.primaryFocus;
      final hasEditableFocus =
          primaryFocus != null &&
          primaryFocus is! FocusScopeNode &&
          primaryFocus.hasPrimaryFocus;
      if (hasEditableFocus) {
        return;
      }
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    });
  }
}
