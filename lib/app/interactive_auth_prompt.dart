import '../domain/services/interactive_auth_prompt.dart';
import '../presentation/widgets/interactive_auth_dialog.dart';
import 'router.dart';

/// Creates the UI-backed interactive authentication prompt handler.
///
/// Shows a dialog (via the app navigator) so the user can answer a
/// server-issued password or keyboard-interactive challenge. Returns `null`
/// when no UI is available or the user cancels, which skips the method.
InteractiveAuthPromptHandler createInteractiveAuthPromptHandler() =>
    (challenge) async {
      final context = appNavigatorKey.currentContext;
      final navigator = appNavigatorKey.currentState;
      if (context == null || navigator == null || !navigator.mounted) {
        return null;
      }
      return showInteractiveAuthDialog(context: context, challenge: challenge);
    };
