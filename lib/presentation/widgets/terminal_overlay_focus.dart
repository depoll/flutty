import 'package:flutter/material.dart';

/// Returns the route focus policy for terminal-adjacent overlays.
///
/// Mobile overlays should not steal focus from the terminal text input client
/// because doing so hides the soft keyboard. Desktop and web keep Flutter's
/// default route focus behavior so keyboard navigation remains available.
bool? terminalOverlayRouteRequestFocus(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      return false;
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      return null;
  }
}
