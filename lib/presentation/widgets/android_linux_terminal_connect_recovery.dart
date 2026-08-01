import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database/database.dart';
import '../../domain/services/android_linux_terminal_setup_service.dart';

/// User choice after a failed Android Linux Terminal SSH connect.
enum AndroidLinuxTerminalConnectRecoveryAction {
  /// Open Terminal (and keep setup helpers warm), then retry connect.
  openTerminalAndRetry,

  /// Retry connect without launching Terminal again.
  retry,

  /// Give up.
  close,
}

/// Whether failed connects for [host] should offer Linux Terminal recovery.
bool shouldOfferAndroidLinuxTerminalConnectRecovery(Host host) =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android &&
    isAndroidLinuxTerminalHost(host);

/// Shows recovery options when SSH to the Linux Terminal VM is unreachable.
Future<AndroidLinuxTerminalConnectRecoveryAction>
showAndroidLinuxTerminalConnectRecoveryDialog({
  required BuildContext context,
  required WidgetRef ref,
  required Host host,
  String? errorMessage,
}) async {
  final setup = ref.read(androidLinuxTerminalSetupServiceProvider);
  final action =
      await showDialog<AndroidLinuxTerminalConnectRecoveryAction>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Linux Terminal not reachable'),
          content: Text(
            errorMessage == null || errorMessage.trim().isEmpty
                ? 'SSH to ${host.username}@${host.hostname}:${host.port} failed. '
                      'The Linux Terminal app/VM is probably not running, or '
                      'port forwarding is not set up yet.'
                : errorMessage,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(AndroidLinuxTerminalConnectRecoveryAction.close),
              child: const Text('Close'),
            ),
            TextButton(
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(AndroidLinuxTerminalConnectRecoveryAction.retry),
              child: const Text('Retry'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                AndroidLinuxTerminalConnectRecoveryAction.openTerminalAndRetry,
              ),
              child: const Text('Open Terminal'),
            ),
          ],
        ),
      ) ??
      AndroidLinuxTerminalConnectRecoveryAction.close;

  if (action ==
      AndroidLinuxTerminalConnectRecoveryAction.openTerminalAndRetry) {
    await setup.prepareConnectRecovery();
    // Soft wait so the VM can start before the next connect attempt.
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  return action;
}
