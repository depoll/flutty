import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/database/database.dart';
import '../../domain/models/monetization.dart';
import '../../domain/services/monetization_service.dart';
import '../../domain/services/ssh_service.dart';

/// Runs a host connection while showing a live progress dialog.
Future<SshConnectionResult> connectToHostWithProgressDialog(
  BuildContext context,
  WidgetRef ref,
  Host host, {
  bool forceNew = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
  final monetizationState =
      ref.read(monetizationStateProvider).asData?.value ??
      ref.read(monetizationServiceProvider).currentState;
  final useHostThemeOverrides = monetizationState.allowsFeature(
    MonetizationFeature.hostSpecificThemes,
  );
  final dialogFuture = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ConnectionAttemptDialog(host: host),
  );

  late final SshConnectionResult result;
  try {
    result = await sessionsNotifier.connect(
      host.id,
      forceNew: forceNew,
      useHostThemeOverrides: useHostThemeOverrides,
    );
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'connection_attempt_dialog',
        context: ErrorDescription('while connecting to host ${host.id}'),
      ),
    );
    sessionsNotifier.reportConnectionAttemptError(host.id, '$error');
    result = SshConnectionResult(success: false, error: '$error');
  }

  if (result.success && result.connectionId != null && navigator.mounted) {
    navigator.pop();
  }

  await dialogFuture;
  sessionsNotifier.clearConnectionAttempt(host.id);
  return result;
}

class _ConnectionAttemptDialog extends ConsumerWidget {
  const _ConnectionAttemptDialog({required this.host});

  final Host host;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(activeSessionsProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final sessionsNotifier = ref.read(activeSessionsProvider.notifier);
    final attempt = sessionsNotifier.getConnectionAttempt(host.id);
    final connectionState = attempt?.state ?? SshConnectionState.connecting;
    final logLines = attempt?.logLines ?? const ['Preparing connection…'];
    final statusMessage = attempt?.latestMessage ?? 'Preparing connection…';
    final canClose = connectionState == SshConnectionState.error;

    return PopScope(
      canPop: canClose,
      child: AlertDialog(
        title: Text(
          canClose ? 'Connection failed' : 'Connecting to ${host.label}',
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${host.username}@${host.hostname}:${host.port}',
                style: FluttyTheme.monoStyle.copyWith(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ConnectionAttemptIcon(state: connectionState),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      statusMessage,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Connection log',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final line in logLines)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          line,
                          style: FluttyTheme.monoStyle.copyWith(
                            fontSize: 10,
                            color: colorScheme.onSurface,
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (canClose)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
        ],
      ),
    );
  }
}

class _ConnectionAttemptIcon extends StatelessWidget {
  const _ConnectionAttemptIcon({required this.state});

  final SshConnectionState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (state) {
      SshConnectionState.connected => Icon(
        Icons.check_circle,
        color: colorScheme.primary,
      ),
      SshConnectionState.error => Icon(
        Icons.error_outline,
        color: colorScheme.error,
      ),
      SshConnectionState.authenticating => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: colorScheme.primary,
        ),
      ),
      _ => SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: colorScheme.primary,
        ),
      ),
    };
  }
}
