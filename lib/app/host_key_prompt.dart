import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/services/host_key_verification.dart';
import '../presentation/widgets/host_key_trust_dialog.dart';
import 'router.dart';

/// Provider for the UI-backed host-key trust prompt handler.
final hostKeyPromptHandlerProvider = Provider<HostKeyPromptHandler?>(
  (ref) => (request) async {
    final context = appNavigatorKey.currentContext;
    final navigator = appNavigatorKey.currentState;
    if (context == null || navigator == null || !navigator.mounted) {
      throw HostKeyVerificationException(
        request.isReplacement
            ? 'The host key for ${request.hostLabel} changed, but the trust '
                  'prompt could not be shown.'
            : 'Host key verification is required for ${request.hostLabel}, but '
                  'the trust prompt could not be shown.',
      );
    }

    return showHostKeyTrustDialog(context: context, request: request);
  },
);
